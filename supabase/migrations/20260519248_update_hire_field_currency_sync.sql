-- =============================================================================
-- Migration 248: Auto-sync base_currency_id when work_country changes
--               in update_hire_field (Gap 5)
--
-- PROBLEM
-- ───────
-- update_hire_field has no case for emp.base_currency_id.
-- The emp.work_country case updates only the work_country column.
-- If an approver or initiator corrects the work country mid-flight, the base
-- currency stays as it was at submission time and falls out of sync — the only
-- fix was a full rejection → correction in AddEmployee → resubmit.
--
-- HOW BASE CURRENCY IS DERIVED
-- ─────────────────────────────
-- The derivation chain is the same one AddEmployee.tsx uses:
--
--   picklist_values[ID_COUNTRY].meta->>'currencyId'
--     → UUID of a CURRENCY picklist value
--     → picklist_values[CURRENCY].value  (e.g. "Indian Rupee")
--     → currencies WHERE name = 'Indian Rupee'
--     → currencies.id  (the FK stored in employees.base_currency_id)
--
-- FIX
-- ───
-- Lift the emp.work_country branch out of the flat CASE statement and handle
-- it as a dedicated block that:
--   1. Updates employees.work_country
--   2. Derives the matching base_currency_id via the chain above
--   3. Updates employees.base_currency_id (RAISES EXCEPTION if no mapping
--      is found — surfaces as a modal error in WorkflowReview so the admin
--      can fix Reference Data → ID Country before retrying)
--
-- SCOPE
-- ─────
-- This is a full CREATE OR REPLACE of update_hire_field, incorporating all
-- changes from mig 242 (ownership guard) and mig 244 (allow Incomplete).
-- No schema or RLS changes.
-- =============================================================================


CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id uuid,
  p_field_key   text,
  p_new_value   text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parts       text[];
  v_record_id   uuid;
  v_col         text;
  v_emp_status  text;
  -- Currency auto-derive
  v_currency_pl_id uuid;
  v_currency_name  text;
  v_currency_id    uuid;
BEGIN
  -- ── Guard 1: caller must be authorised ───────────────────────────────────
  -- PATH A — workflow submitter for this employee
  -- PATH B — holds hire_employee.edit (HR Head / admin)
  IF NOT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION
      'Not authorised to edit hire fields for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Guard 2: employee must be Pending or Incomplete ───────────────────────
  -- Pending    = locked mid-approval  (approver inline edit)
  -- Incomplete = returned for fixes   (initiator post-send-back edit)
  -- Active employees are never writable via this function.
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status IN ('Pending', 'Incomplete')
  ) THEN
    RAISE EXCEPTION
      'Cannot edit hire fields: employee is not in Pending or Incomplete status (id=%, status=%).',
      p_employee_id,
      (SELECT status FROM employees WHERE id = p_employee_id);
  END IF;

  -- ── identity_records: key format  id.<uuid>.<column> ─────────────────────
  IF p_field_key LIKE 'id.%.%' THEN
    v_parts     := string_to_array(p_field_key, '.');
    v_record_id := v_parts[2]::uuid;
    v_col       := v_parts[3];
    CASE v_col
      WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'expiry'      THEN UPDATE identity_records SET expiry       = NULLIF(p_new_value,'')::date  WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'country'     THEN UPDATE identity_records SET country      = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'id_type'     THEN UPDATE identity_records SET id_type      = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'record_type' THEN UPDATE identity_records SET record_type  = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
    END CASE;
    RETURN;
  END IF;

  -- ── emp.work_country — special case: also auto-derives base_currency_id ──
  -- Handled before the flat CASE to allow multi-step logic.
  -- Derivation: country picklist meta->currencyId → CURRENCY picklist value
  --             → currencies.name match → currencies.id (FK)
  IF p_field_key = 'emp.work_country' THEN

    -- Step 1: get the CURRENCY picklist value UUID from the country's meta
    SELECT (meta->>'currencyId')::uuid
    INTO   v_currency_pl_id
    FROM   picklist_values
    WHERE  id = p_new_value::uuid
    LIMIT  1;

    -- Step 2: get the currency name from the CURRENCY picklist value
    IF v_currency_pl_id IS NOT NULL THEN
      SELECT value INTO v_currency_name
      FROM   picklist_values
      WHERE  id = v_currency_pl_id
      LIMIT  1;
    END IF;

    -- Step 3: look up currencies.id by name
    IF v_currency_name IS NOT NULL THEN
      SELECT id INTO v_currency_id
      FROM   currencies
      WHERE  name = v_currency_name
        AND  active = true
      LIMIT  1;
    END IF;

    -- Step 4: update both columns atomically
    -- base_currency_id is only overwritten when a mapping is found (v_currency_id IS NOT NULL).
    -- If the country has no currencyId in its meta (shouldn't happen with seeded data), the
    -- existing base_currency_id is preserved and a NOTICE is raised for visibility.
    IF v_currency_id IS NOT NULL THEN
      UPDATE employees
      SET    work_country     = p_new_value,
             base_currency_id = v_currency_id,
             updated_at       = now()
      WHERE  id = p_employee_id;
    ELSE
      -- No currency mapping found — block the save and surface a clear error.
      -- The caller (update_hire_field RPC) returns this as an error; WorkflowReview
      -- shows it in the "Some fields could not be saved" modal so the user knows
      -- exactly what to fix before retrying.
      RAISE EXCEPTION
        'No default currency is configured for this country. '
        'Ask your administrator to set a Default Currency for this country in '
        'Reference Data → ID Country before saving Work Country.';
    END IF;

    RETURN;
  END IF;

  -- ── All other fields ──────────────────────────────────────────────────────
  CASE p_field_key

    -- employees
    WHEN 'emp.name'            THEN UPDATE employees SET name           = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;
    -- NOTE: emp.work_country is handled above (exits with RETURN) because
    --       it must also update base_currency_id atomically.

    -- employee_personal
    WHEN 'personal.nationality' THEN
      INSERT INTO employee_personal (employee_id, nationality) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET nationality = EXCLUDED.nationality;
    WHEN 'personal.gender' THEN
      INSERT INTO employee_personal (employee_id, gender) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET gender = EXCLUDED.gender;
    WHEN 'personal.dob' THEN
      INSERT INTO employee_personal (employee_id, dob) VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET dob = EXCLUDED.dob;
    WHEN 'personal.marital_status' THEN
      INSERT INTO employee_personal (employee_id, marital_status) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET marital_status = EXCLUDED.marital_status;

    -- employee_contact
    WHEN 'contact.personal_email' THEN
      INSERT INTO employee_contact (employee_id, personal_email) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET personal_email = EXCLUDED.personal_email;
    WHEN 'contact.mobile' THEN
      INSERT INTO employee_contact (employee_id, mobile) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET mobile = EXCLUDED.mobile;
    WHEN 'contact.country_code' THEN
      INSERT INTO employee_contact (employee_id, country_code) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET country_code = EXCLUDED.country_code;

    -- employee_employment
    WHEN 'employment.probation_end_date' THEN
      INSERT INTO employee_employment (employee_id, probation_end_date)
      VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET probation_end_date = EXCLUDED.probation_end_date;

    -- employee_addresses
    WHEN 'addr.line1'    THEN INSERT INTO employee_addresses (employee_id, line1)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line1    = EXCLUDED.line1;
    WHEN 'addr.line2'    THEN INSERT INTO employee_addresses (employee_id, line2)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line2    = EXCLUDED.line2;
    WHEN 'addr.landmark' THEN INSERT INTO employee_addresses (employee_id, landmark) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET landmark = EXCLUDED.landmark;
    WHEN 'addr.city'     THEN INSERT INTO employee_addresses (employee_id, city)     VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET city     = EXCLUDED.city;
    WHEN 'addr.district' THEN INSERT INTO employee_addresses (employee_id, district) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET district = EXCLUDED.district;
    WHEN 'addr.state'    THEN INSERT INTO employee_addresses (employee_id, state)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET state    = EXCLUDED.state;
    WHEN 'addr.pin'      THEN INSERT INTO employee_addresses (employee_id, pin)      VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET pin      = EXCLUDED.pin;
    WHEN 'addr.country'  THEN INSERT INTO employee_addresses (employee_id, country)  VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET country  = EXCLUDED.country;

    -- passports
    WHEN 'passport.country'         THEN UPDATE passports SET country         = p_new_value                   WHERE employee_id = p_employee_id;
    WHEN 'passport.passport_number' THEN UPDATE passports SET passport_number = p_new_value                   WHERE employee_id = p_employee_id;
    WHEN 'passport.issue_date'      THEN UPDATE passports SET issue_date      = NULLIF(p_new_value,'')::date  WHERE employee_id = p_employee_id;
    WHEN 'passport.expiry_date'     THEN UPDATE passports SET expiry_date     = NULLIF(p_new_value,'')::date  WHERE employee_id = p_employee_id;

    -- emergency_contacts
    WHEN 'ec.name'         THEN UPDATE emergency_contacts SET name         = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.relationship' THEN UPDATE emergency_contacts SET relationship = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.phone'        THEN UPDATE emergency_contacts SET phone        = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.alt_phone'    THEN UPDATE emergency_contacts SET alt_phone    = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.email'        THEN UPDATE emergency_contacts SET email        = p_new_value WHERE employee_id = p_employee_id;

    ELSE RAISE EXCEPTION 'Unknown field key: %', p_field_key;
  END CASE;
END;
$$;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Inline-edit RPC for hire review. '
  'Guard 1: caller must be the workflow submitter (PATH A) or hold hire_employee.edit (PATH B). '
  'Guard 2: employee must be Pending (approver inline edit) or Incomplete (initiator post-send-back edit). '
  'Active employees are never writable via this function. '
  'emp.work_country: also auto-derives and updates base_currency_id via '
  '  picklist_values[ID_COUNTRY].meta->currencyId → CURRENCY picklist '
  '  → currencies.name match → currencies.id. '
  'Mig 242: ownership guard. Mig 244: allow Incomplete. '
  'Mig 248: work_country auto-syncs base_currency_id (Gap 5).';

REVOKE ALL ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Also update get_employee_hire_review: make Base Currency show
-- "(auto from country)" note in the label so reviewers understand it updates
-- automatically — no UI action needed.
-- The field stays editable=false / input_type=readonly as before.
-- We just update the label for clarity.
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE: get_employee_hire_review was last replaced in mig 246.
--       Only the Base Currency label line changes; everything else is identical.

CREATE OR REPLACE FUNCTION get_employee_hire_review(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id         text;
  v_name           text;
  v_business_email text;
  v_designation    text;
  v_dept_id        uuid;
  v_manager_id     uuid;
  v_hire_date      date;
  v_end_date       date;
  v_work_country   text;
  v_work_location  text;
  v_base_curr_id   uuid;
  v_status         text;

  v_nationality    text;
  v_marital_raw    text;
  v_gender         text;
  v_dob            date;

  v_contact    employee_contact%ROWTYPE;
  v_employment employee_employment%ROWTYPE;
  v_addr       employee_addresses%ROWTYPE;
  v_passport   passports%ROWTYPE;
  v_ec         emergency_contacts%ROWTYPE;

  v_dept                   text;
  v_manager                text;
  v_currency               text;
  v_designation_label      text;
  v_work_country_label     text;
  v_work_location_label    text;
  v_marital_label          text;
  v_passport_country_lbl   text;
  v_ec_relationship_lbl    text;

  v_id_rec          identity_records%ROWTYPE;
  v_id_idx          int := 0;
  v_id_country_raw  text;
  v_id_type_raw     text;
  v_id_rectype_raw  text;
  v_id_country_lbl  text;
  v_id_type_lbl     text;
  v_id_rectype_lbl  text;
  v_id_key_prefix   text;

  v_passport_required boolean;

  v_result   jsonb := '[]'::jsonb;
BEGIN
  SELECT
    employee_id, name, business_email, designation,
    dept_id, manager_id, hire_date, end_date,
    work_country, work_location, base_currency_id, status::text
  INTO
    v_emp_id, v_name, v_business_email, v_designation,
    v_dept_id, v_manager_id, v_hire_date, v_end_date,
    v_work_country, v_work_location, v_base_curr_id, v_status
  FROM employees WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  SELECT name INTO v_dept    FROM departments WHERE id = v_dept_id;
  SELECT name INTO v_manager FROM employees   WHERE id = v_manager_id;
  SELECT code INTO v_currency FROM currencies WHERE id = v_base_curr_id;

  SELECT value INTO v_designation_label
  FROM   picklist_values WHERE id::text = v_designation LIMIT 1;
  v_designation_label := COALESCE(v_designation_label, v_designation);

  SELECT value INTO v_work_country_label
  FROM   picklist_values WHERE id::text = v_work_country LIMIT 1;
  v_work_country_label := COALESCE(v_work_country_label, v_work_country);

  SELECT value INTO v_work_location_label
  FROM   picklist_values WHERE id::text = v_work_location LIMIT 1;
  v_work_location_label := COALESCE(v_work_location_label, v_work_location);

  SELECT nationality, marital_status, gender, dob
  INTO   v_nationality, v_marital_raw, v_gender, v_dob
  FROM   employee_personal WHERE employee_id = p_employee_id;

  IF v_marital_raw IS NOT NULL THEN
    SELECT value INTO v_marital_label
    FROM   picklist_values WHERE id::text = v_marital_raw LIMIT 1;
    v_marital_label := COALESCE(v_marital_label, v_marital_raw);
  END IF;

  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id;
  SELECT * INTO v_employment FROM employee_employment WHERE employee_id = p_employee_id;
  SELECT * INTO v_addr       FROM employee_addresses  WHERE employee_id = p_employee_id;
  SELECT * INTO v_passport   FROM passports           WHERE employee_id = p_employee_id;
  SELECT * INTO v_ec         FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  IF v_passport.country IS NOT NULL THEN
    SELECT value INTO v_passport_country_lbl
    FROM   picklist_values WHERE id::text = v_passport.country LIMIT 1;
    v_passport_country_lbl := COALESCE(v_passport_country_lbl, v_passport.country);
  END IF;

  v_passport_required := (v_passport.country IS NOT NULL);

  IF v_ec.relationship IS NOT NULL THEN
    SELECT value INTO v_ec_relationship_lbl
    FROM   picklist_values WHERE id::text = v_ec.relationship LIMIT 1;
    v_ec_relationship_lbl := COALESCE(v_ec_relationship_lbl, v_ec.relationship);
  END IF;

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Employee ID',    'value',COALESCE(v_emp_id,        '—'),'raw_value',v_emp_id,       'key','emp.employee_id',        'editable',false,'input_type','readonly', 'required',false),
      jsonb_build_object('label','Full Name',      'value',COALESCE(v_name,          '—'),'raw_value',v_name,         'key','emp.name',               'editable',true, 'input_type','text',     'required',true),
      jsonb_build_object('label','Nationality',    'value',COALESCE(v_nationality,   '—'),'raw_value',v_nationality,  'key','personal.nationality',   'editable',true, 'input_type','select',   'required',true),
      jsonb_build_object('label','Marital Status', 'value',COALESCE(v_marital_label, '—'),'raw_value',v_marital_raw,  'key','personal.marital_status','editable',true, 'input_type','select',   'required',true),
      jsonb_build_object('label','Gender',         'value',COALESCE(v_gender,        '—'),'raw_value',v_gender,       'key','personal.gender',        'editable',true, 'input_type','select',   'required',true),
      jsonb_build_object('label','Date of Birth',  'value',COALESCE(v_dob::text,     '—'),'raw_value',v_dob::text,    'key','personal.dob',           'editable',true, 'input_type','date',     'required',true),
      jsonb_build_object('label','Status',         'value',COALESCE(v_status,        '—'),'raw_value',v_status,       'key','emp.status',             'editable',false,'input_type','readonly', 'required',false)
    )
  );

  -- ── Section 2: Contact ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Business Email', 'value',COALESCE(v_business_email,           '—'),'raw_value',v_business_email,           'key','emp.business_email',     'editable',true,'input_type','email',      'required',true),
      jsonb_build_object('label','Personal Email', 'value',COALESCE(v_contact.personal_email,   '—'),'raw_value',v_contact.personal_email,   'key','contact.personal_email', 'editable',true,'input_type','email',      'required',true),
      jsonb_build_object('label','Country Code',   'value',COALESCE(v_contact.country_code,     '—'),'raw_value',v_contact.country_code,     'key','contact.country_code',   'editable',true,'input_type','phone_code', 'required',true),
      jsonb_build_object('label','Mobile',         'value',COALESCE(v_contact.mobile,           '—'),'raw_value',v_contact.mobile,           'key','contact.mobile',         'editable',true,'input_type','text',       'required',true)
    )
  );

  -- ── Section 3: Employment ─────────────────────────────────────────────────
  -- Base Currency is read-only and auto-derived from Work Country.
  -- When emp.work_country is saved, update_hire_field also updates
  -- base_currency_id automatically — no separate edit action needed.
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Designation',   'value',COALESCE(v_designation_label,                 '—'),'raw_value',v_designation,              'key','emp.designation',              'editable',true, 'input_type','select',      'required',true),
      jsonb_build_object('label','Department',    'value',COALESCE(v_dept,                               '—'),'raw_value',v_dept_id::text,             'key','emp.dept_id',                  'editable',true, 'input_type','dept_select', 'required',true),
      jsonb_build_object('label','Manager',       'value',COALESCE(v_manager,                            '—'),'raw_value',v_manager_id::text,          'key','emp.manager_id',               'editable',true, 'input_type','emp_select',  'required',false),
      jsonb_build_object('label','Hire Date',     'value',COALESCE(v_hire_date::text,                    '—'),'raw_value',v_hire_date::text,           'key','emp.hire_date',                'editable',true, 'input_type','date',        'required',true),
      jsonb_build_object('label','Probation End', 'value',COALESCE(v_employment.probation_end_date::text,'—'),'raw_value',v_employment.probation_end_date::text,'key','employment.probation_end_date','editable',true,'input_type','date','required',true),
      jsonb_build_object('label','Work Country',  'value',COALESCE(v_work_country_label,                 '—'),'raw_value',v_work_country,             'key','emp.work_country',             'editable',true, 'input_type','select',      'required',true),
      jsonb_build_object('label','Work Location', 'value',COALESCE(v_work_location_label,                '—'),'raw_value',v_work_location,            'key','emp.work_location',            'editable',true, 'input_type','select',      'required',true),
      jsonb_build_object('label','Base Currency', 'value',COALESCE(v_currency,                           '—'),'raw_value',v_base_curr_id::text,       'key','emp.base_currency_id',         'editable',false,'input_type','readonly',   'required',false,
                         'hint', 'Auto-derived from Work Country')
    )
  );

  -- ── Section 4: Address ───────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Address',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Line 1',   'value',COALESCE(v_addr.line1,   '—'),'raw_value',v_addr.line1,   'key','addr.line1',   'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Line 2',   'value',COALESCE(v_addr.line2,   '—'),'raw_value',v_addr.line2,   'key','addr.line2',   'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Landmark', 'value',COALESCE(v_addr.landmark,'—'),'raw_value',v_addr.landmark,'key','addr.landmark','editable',true,'input_type','text','required',false),
      jsonb_build_object('label','City',     'value',COALESCE(v_addr.city,    '—'),'raw_value',v_addr.city,    'key','addr.city',    'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','District', 'value',COALESCE(v_addr.district,'—'),'raw_value',v_addr.district,'key','addr.district','editable',true,'input_type','text','required',false),
      jsonb_build_object('label','State',    'value',COALESCE(v_addr.state,   '—'),'raw_value',v_addr.state,   'key','addr.state',   'editable',true,'input_type','text','required',false),
      jsonb_build_object('label','PIN',      'value',COALESCE(v_addr.pin,     '—'),'raw_value',v_addr.pin,     'key','addr.pin',     'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Country',  'value',COALESCE(v_addr.country, '—'),'raw_value',v_addr.country, 'key','addr.country', 'editable',true,'input_type','text','required',true)
    )
  );

  -- ── Section 5: Passport ──────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Passport',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Country',         'value',COALESCE(v_passport_country_lbl,      '—'),'raw_value',v_passport.country,          'key','passport.country',         'editable',true,'input_type','select','required',false),
      jsonb_build_object('label','Passport Number', 'value',COALESCE(v_passport.passport_number,  '—'),'raw_value',v_passport.passport_number,  'key','passport.passport_number', 'editable',true,'input_type','text',  'required',v_passport_required),
      jsonb_build_object('label','Issue Date',      'value',COALESCE(v_passport.issue_date::text, '—'),'raw_value',v_passport.issue_date::text,  'key','passport.issue_date',      'editable',true,'input_type','date',  'required',v_passport_required),
      jsonb_build_object('label','Expiry Date',     'value',COALESCE(v_passport.expiry_date::text,'—'),'raw_value',v_passport.expiry_date::text, 'key','passport.expiry_date',     'editable',true,'input_type','date',  'required',v_passport_required)
    )
  );

  -- ── Section 6: Emergency Contact ─────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Emergency Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Name',         'value',COALESCE(v_ec.name,              '—'),'raw_value',v_ec.name,        'key','ec.name',        'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Relationship', 'value',COALESCE(v_ec_relationship_lbl,  '—'),'raw_value',v_ec.relationship,'key','ec.relationship','editable',true,'input_type','select','required',true),
      jsonb_build_object('label','Phone',        'value',COALESCE(v_ec.phone,             '—'),'raw_value',v_ec.phone,       'key','ec.phone',       'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Alt Phone',    'value',COALESCE(v_ec.alt_phone,         '—'),'raw_value',v_ec.alt_phone,  'key','ec.alt_phone',   'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','Email',        'value',COALESCE(v_ec.email,             '—'),'raw_value',v_ec.email,      'key','ec.email',       'editable',true,'input_type','email', 'required',false)
    )
  );

  -- ── Section 7: Identity Documents ────────────────────────────────────────
  FOR v_id_rec IN
    SELECT * FROM identity_records
    WHERE  employee_id = p_employee_id
    ORDER  BY created_at
  LOOP
    v_id_idx       := v_id_idx + 1;
    v_id_key_prefix := 'id.' || v_id_rec.id::text;

    v_id_country_raw := v_id_rec.country;
    v_id_type_raw    := v_id_rec.id_type;
    v_id_rectype_raw := v_id_rec.record_type;

    SELECT value INTO v_id_country_lbl FROM picklist_values WHERE id::text = v_id_country_raw LIMIT 1;
    v_id_country_lbl := COALESCE(v_id_country_lbl, v_id_country_raw);

    SELECT value INTO v_id_type_lbl FROM picklist_values WHERE id::text = v_id_type_raw LIMIT 1;
    v_id_type_lbl := COALESCE(v_id_type_lbl, v_id_type_raw);

    SELECT value INTO v_id_rectype_lbl FROM picklist_values WHERE id::text = v_id_rectype_raw LIMIT 1;
    v_id_rectype_lbl := COALESCE(v_id_rectype_lbl, v_id_rectype_raw);

    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document ' || v_id_idx,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl, '—'),'raw_value',v_id_country_raw,'key',v_id_key_prefix||'.country',    'editable',true, 'input_type','select','required',false),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,   '—'),'raw_value',v_id_type_raw,   'key',v_id_key_prefix||'.id_type',    'editable',true, 'input_type','select','required',false),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,'—'),'raw_value',v_id_rectype_raw,'key',v_id_key_prefix||'.record_type','editable',true, 'input_type','select','required',false),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,  '—'),'raw_value',v_id_rec.id_number,  'key',v_id_key_prefix||'.id_number','editable',true,'input_type','text','required',false),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text,'key',v_id_key_prefix||'.expiry','editable',true,'input_type','date','required',false)
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all hire sections as JSONB with full edit metadata including required flag. '
  'UUID-keyed picklist fields: designation, work_country, work_location, marital_status, '
  'passport.country (ID_COUNTRY), ec.relationship (RELATIONSHIP_TYPE), '
  'id.*.country (ID_COUNTRY), id.*.id_type (ID_TYPE). '
  'FK table fields: dept_id (dept_select → departments), manager_id (emp_select → employees). '
  'Text-stored fields: nationality, gender, record_type. '
  'Contact section: country_code (input_type=phone_code → PHONE_CODES select), '
  'mobile (input_type=text). Stored separately in employee_contact. '
  'Base Currency: readonly, hint=Auto-derived from Work Country. '
  'required=true mirrors AddEmployee.tsx validation rules. '
  'Mig 246: split combined mobile into Country Code (phone_code) + Mobile rows. '
  'Mig 248: Base Currency hint added; auto-sync handled in update_hire_field.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Frontend note (no code change needed):
-- WorkflowReview.tsx renders readonly fields with ev-field-value class, not an
-- input. The 'hint' key in the JSONB is available for future UI use (e.g. a
-- small italic note under the value), but the field already shows the correct
-- currency code and updates on the next get_employee_hire_review fetch after
-- work_country is saved via Done Editing.
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'update_hire_field'
  ) THEN
    RAISE EXCEPTION 'ABORT: update_hire_field not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'get_employee_hire_review'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_employee_hire_review not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 248 verified: both functions present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 248
--
-- After this migration:
--   update_hire_field  — emp.work_country now also auto-updates base_currency_id
--                        using the same picklist meta→currencies derivation as
--                        AddEmployee.tsx. No currency drift possible.
--   get_employee_hire_review — Base Currency field gains hint='Auto-derived from
--                        Work Country' for future UI display.
--
-- No schema changes. No type regen needed.
-- No frontend changes needed — WorkflowReview.tsx already re-fetches sections
-- after Done Editing; the updated currency code will appear on next load.
-- =============================================================================
