-- =============================================================================
-- Migration 333 — Hire review: replace Full Name with first/middle/last name
-- =============================================================================
--
-- CONTEXT
-- ───────
-- Mig 332 added first_name / last_name to employee_personal and updated
-- upsert_personal_info to accept them. This migration updates the hire review
-- layer to match:
--
--   get_employee_hire_review
--     • Fetches first_name, middle_name, last_name from employee_personal
--     • Personal Info section: replaces the single "Full Name" (emp.name)
--       field with three separate rows:
--         First Name  (key: personal.first_name,  required, editable)
--         Middle Name (key: personal.middle_name, optional, editable)
--         Last Name   (key: personal.last_name,   optional, editable)
--
--   update_hire_field
--     • Adds handlers for personal.first_name / personal.middle_name /
--       personal.last_name — each calls upsert_personal_info so the
--       computed name is automatically updated on employee_personal.
--     • Removes the emp.name handler (name is now computed, not set directly).
--       emp.name writes are blocked for Active employees by the guard trigger;
--       during the hire pipeline, name is derived from first+last.
--
-- NOTE ON employee_personal UPSERTS IN update_hire_field
-- ──────────────────────────────────────────────────────
-- The old update_hire_field used direct INSERT ... ON CONFLICT (employee_id)
-- on employee_personal. Since mig 315 converted employee_personal to a
-- multi-row effective-dated table (employee_id is no longer UNIQUE), those
-- upserts are broken for the personal.* fields. This migration fixes them by
-- routing through upsert_personal_info (which carries forward unchanged fields
-- and recomputes the name). The remaining personal.* fields (nationality,
-- gender, dob, marital_status) are also moved to upsert_personal_info.
-- =============================================================================


-- =============================================================================
-- 1. get_employee_hire_review — add first_name / last_name to Personal Info
-- =============================================================================

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

  v_first_name     text;
  v_middle_name    text;
  v_last_name      text;
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

  v_bank_rec    RECORD;
  v_bank_idx    int := 0;
  v_bank_label  text;

  v_dep_rec      RECORD;
  v_dep_idx      int := 0;
  v_dep_label    text;
  v_dep_rel_lbl  text;

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

  -- Fetch structured name fields + personal fields from employee_personal.
  -- For hire pipeline employees this row was created by AddEmployee via
  -- upsert_personal_info. If not yet present, first_name defaults to
  -- the split of employees.name (same logic as wf_activate_employee).
  SELECT first_name, middle_name, last_name,
         nationality, marital_status, gender, dob
  INTO   v_first_name, v_middle_name, v_last_name,
         v_nationality, v_marital_raw, v_gender, v_dob
  FROM   employee_personal
  WHERE  employee_id = p_employee_id
  LIMIT  1;

  -- Fallback: if no employee_personal row yet, split employees.name
  IF v_first_name IS NULL THEN
    v_first_name := CASE
      WHEN position(' ' IN v_name) > 0
        THEN left(v_name, length(v_name) - length(split_part(v_name, ' ', -1)) - 1)
      ELSE v_name
    END;
    v_last_name := CASE
      WHEN position(' ' IN v_name) > 0 THEN split_part(v_name, ' ', -1)
      ELSE NULL
    END;
  END IF;

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
      jsonb_build_object('label','Employee ID',    'value',COALESCE(v_emp_id,           '—'),'raw_value',v_emp_id,          'key','emp.employee_id',        'editable',false,'input_type','readonly','required',false),
      jsonb_build_object('label','First Name',     'value',COALESCE(v_first_name,        '—'),'raw_value',v_first_name,      'key','personal.first_name',    'editable',true, 'input_type','text',    'required',true),
      jsonb_build_object('label','Middle Name',    'value',COALESCE(v_middle_name,       '—'),'raw_value',v_middle_name,     'key','personal.middle_name',   'editable',true, 'input_type','text',    'required',false),
      jsonb_build_object('label','Last Name',      'value',COALESCE(v_last_name,         '—'),'raw_value',v_last_name,       'key','personal.last_name',     'editable',true, 'input_type','text',    'required',false),
      jsonb_build_object('label','Nationality',    'value',COALESCE(v_nationality,       '—'),'raw_value',v_nationality,     'key','personal.nationality',   'editable',true, 'input_type','select',  'required',true),
      jsonb_build_object('label','Marital Status', 'value',COALESCE(v_marital_label,     '—'),'raw_value',v_marital_raw,     'key','personal.marital_status','editable',true, 'input_type','select',  'required',true),
      jsonb_build_object('label','Gender',         'value',COALESCE(v_gender,            '—'),'raw_value',v_gender,          'key','personal.gender',        'editable',true, 'input_type','select',  'required',true),
      jsonb_build_object('label','Date of Birth',  'value',COALESCE(v_dob::text,         '—'),'raw_value',v_dob::text,       'key','personal.dob',           'editable',true, 'input_type','date',    'required',true),
      jsonb_build_object('label','Status',         'value',COALESCE(v_status,            '—'),'raw_value',v_status,          'key','emp.status',             'editable',false,'input_type','readonly','required',false)
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
      jsonb_build_object('label','Base Currency', 'value',COALESCE(v_currency,                           '—'),'raw_value',v_base_curr_id::text,       'key','emp.base_currency_id',         'editable',false,'input_type','readonly',   'required',false)
    )
  );

  -- ── Section 4: Identity Documents ────────────────────────────────────────
  FOR v_id_rec IN
    SELECT * FROM identity_records
    WHERE  employee_id = p_employee_id
    ORDER  BY created_at
  LOOP
    v_id_idx        := v_id_idx + 1;
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
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl, '—'),'raw_value',v_id_country_raw,'key',v_id_key_prefix||'.country',    'editable',true,'input_type','select','required',true),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,    '—'),'raw_value',v_id_type_raw,   'key',v_id_key_prefix||'.id_type',     'editable',true,'input_type','select','required',true),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl, '—'),'raw_value',v_id_rectype_raw,'key',v_id_key_prefix||'.record_type', 'editable',true,'input_type','select','required',true),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,'—'),'raw_value',v_id_rec.id_number,'key',v_id_key_prefix||'.id_number','editable',true,'input_type','text', 'required',true),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text,'key',v_id_key_prefix||'.expiry','editable',true,'input_type','date','required',false)
      )
    );
  END LOOP;

  -- If no identity records, show a placeholder section so the approver can add one
  IF v_id_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',     'value','—','raw_value',null,'key','id.new.country',    'editable',true,'input_type','select','required',true),
        jsonb_build_object('label','ID Type',     'value','—','raw_value',null,'key','id.new.id_type',    'editable',true,'input_type','select','required',true),
        jsonb_build_object('label','Record Type', 'value','—','raw_value',null,'key','id.new.record_type','editable',true,'input_type','select','required',true),
        jsonb_build_object('label','ID Number',   'value','—','raw_value',null,'key','id.new.id_number',  'editable',true,'input_type','text', 'required',true),
        jsonb_build_object('label','Expiry',      'value','—','raw_value',null,'key','id.new.expiry',     'editable',true,'input_type','date', 'required',false)
      )
    );
  END IF;

  -- ── Section 5: Passport ───────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Passport',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Country',       'value',COALESCE(v_passport_country_lbl,       '—'),'raw_value',v_passport.country,          'key','passport.country',       'editable',true,'input_type','select','required',false),
      jsonb_build_object('label','Passport No.',  'value',COALESCE(v_passport.passport_number,   '—'),'raw_value',v_passport.passport_number,  'key','passport.passport_number','editable',true,'input_type','text', 'required',v_passport_required),
      jsonb_build_object('label','Issue Date',    'value',COALESCE(v_passport.issue_date::text,  '—'),'raw_value',v_passport.issue_date::text, 'key','passport.issue_date',     'editable',true,'input_type','date', 'required',v_passport_required),
      jsonb_build_object('label','Expiry Date',   'value',COALESCE(v_passport.expiry_date::text, '—'),'raw_value',v_passport.expiry_date::text,'key','passport.expiry_date',    'editable',true,'input_type','date', 'required',v_passport_required)
    )
  );

  -- ── Section 6: Address ───────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Address',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Line 1',    'value',COALESCE(v_addr.line1,    '—'),'raw_value',v_addr.line1,    'key','addr.line1',    'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Line 2',    'value',COALESCE(v_addr.line2,    '—'),'raw_value',v_addr.line2,    'key','addr.line2',    'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','Landmark',  'value',COALESCE(v_addr.landmark, '—'),'raw_value',v_addr.landmark, 'key','addr.landmark', 'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','City',      'value',COALESCE(v_addr.city,     '—'),'raw_value',v_addr.city,     'key','addr.city',     'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','District',  'value',COALESCE(v_addr.district, '—'),'raw_value',v_addr.district, 'key','addr.district', 'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','State',     'value',COALESCE(v_addr.state,    '—'),'raw_value',v_addr.state,    'key','addr.state',    'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','PIN / ZIP', 'value',COALESCE(v_addr.pin,      '—'),'raw_value',v_addr.pin,      'key','addr.pin',      'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Country',   'value',COALESCE(v_addr.country,  '—'),'raw_value',v_addr.country,  'key','addr.country',  'editable',true,'input_type','select','required',true)
    )
  );

  -- ── Section 7: Emergency Contact ─────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Emergency Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Name',          'value',COALESCE(v_ec.name,          '—'),'raw_value',v_ec.name,          'key','ec.name',         'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Relationship',  'value',COALESCE(v_ec_relationship_lbl,'—'),'raw_value',v_ec.relationship,'key','ec.relationship', 'editable',true,'input_type','select','required',true),
      jsonb_build_object('label','Phone',         'value',COALESCE(v_ec.phone,         '—'),'raw_value',v_ec.phone,         'key','ec.phone',        'editable',true,'input_type','text',  'required',true),
      jsonb_build_object('label','Alt. Phone',    'value',COALESCE(v_ec.alt_phone,     '—'),'raw_value',v_ec.alt_phone,     'key','ec.alt_phone',    'editable',true,'input_type','text',  'required',false),
      jsonb_build_object('label','Email',         'value',COALESCE(v_ec.email,         '—'),'raw_value',v_ec.email,         'key','ec.email',        'editable',true,'input_type','email', 'required',false)
    )
  );

  -- ── Sections 8+: Bank Accounts (set-snapshot tables, mig 328+332) ─────────
  FOR v_bank_rec IN
    SELECT i.bank_account_group_id, i.bank_name, i.account_number,
           i.account_holder_name, i.currency_code, i.is_primary
    FROM   employee_bank_account_item i
    JOIN   employee_bank_account_set  s ON s.id = i.set_id
    WHERE  s.employee_id  = p_employee_id
      AND  s.effective_to = '9999-12-31'::date
      AND  s.is_active    = true
    ORDER  BY i.is_primary DESC, i.bank_name
  LOOP
    v_bank_idx  := v_bank_idx + 1;
    v_bank_label := CASE WHEN v_bank_rec.is_primary THEN 'Bank Account (Primary)' ELSE 'Bank Account ' || v_bank_idx END;

    v_result := v_result || jsonb_build_object(
      'section', v_bank_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Bank Name',      'value',COALESCE(v_bank_rec.bank_name,'—'),           'raw_value',v_bank_rec.bank_name,           'key','bank.'||v_bank_rec.bank_account_group_id::text||'.bank_name',       'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Number', 'value',COALESCE(v_bank_rec.account_number,'—'),      'raw_value',v_bank_rec.account_number,      'key','bank.'||v_bank_rec.bank_account_group_id::text||'.account_number', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Holder', 'value',COALESCE(v_bank_rec.account_holder_name,'—'), 'raw_value',v_bank_rec.account_holder_name, 'key','bank.'||v_bank_rec.bank_account_group_id::text||'.account_holder', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Currency',       'value',COALESCE(v_bank_rec.currency_code,'—'),       'raw_value',v_bank_rec.currency_code,       'key','bank.'||v_bank_rec.bank_account_group_id::text||'.currency_code',  'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  -- ── Sections N+: Dependents (set-snapshot tables, mig 320+332) ───────────
  FOR v_dep_rec IN
    SELECT i.id, i.dependent_code, i.dependent_name, i.relationship_type, i.dob
    FROM   employee_dependent_item i
    JOIN   employee_dependent_set  s ON s.id = i.set_id
    WHERE  s.employee_id  = p_employee_id
      AND  s.effective_to = '9999-12-31'::date
      AND  s.is_active    = true
    ORDER  BY i.dependent_code
  LOOP
    v_dep_idx  := v_dep_idx + 1;
    v_dep_label := 'Dependent ' || v_dep_idx;

    IF v_dep_rec.relationship_type IS NOT NULL THEN
      SELECT value INTO v_dep_rel_lbl
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'DEPENDENT_RELATIONSHIP_TYPE'
        AND  pv.ref_id = v_dep_rec.relationship_type
      LIMIT 1;
      v_dep_rel_lbl := COALESCE(v_dep_rel_lbl, v_dep_rec.relationship_type);
    END IF;

    v_result := v_result || jsonb_build_object(
      'section', v_dep_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',         'value',COALESCE(v_dep_rec.dependent_name, '—'), 'raw_value',v_dep_rec.dependent_name,    'key','dep.'||v_dep_rec.id::text||'.dependent_name',    'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Relationship', 'value',COALESCE(v_dep_rel_lbl,            '—'), 'raw_value',v_dep_rec.relationship_type, 'key','dep.'||v_dep_rec.id::text||'.relationship_type', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Date of Birth','value',COALESCE(v_dep_rec.dob::text,       '—'), 'raw_value',v_dep_rec.dob::text,         'key','dep.'||v_dep_rec.id::text||'.dob',               'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

REVOKE ALL     ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all hire review sections as a jsonb array for the workflow review UI. '
  'Mig 333: Personal Info section now returns first_name / middle_name / last_name '
  'instead of a single Full Name field. Routes personal field saves through '
  'upsert_personal_info to keep computed name in sync.';


-- =============================================================================
-- 2. update_hire_field — add first/middle/last name handlers
-- =============================================================================
-- Full replacement of the function to:
--   a) Add personal.first_name / personal.middle_name / personal.last_name
--   b) Remove emp.name (now computed — not set directly)
--   c) Fix personal.* upserts: route through upsert_personal_info instead of
--      direct INSERT ... ON CONFLICT (which broke after mig 315 made
--      employee_personal multi-row)
-- =============================================================================

CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id  uuid,
  p_field_key    text,
  p_new_value    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parts    text[];
  v_prefix   text;
  v_col      text;
  v_target   uuid;
  v_pi_result jsonb;
  v_today    date := CURRENT_DATE;
BEGIN

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('hire_employee', 'edit', NULL)
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied: you do not have permission to edit this hire record.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_parts  := string_to_array(p_field_key, '.');
  v_prefix := v_parts[1];

  -- ── Identity records (id.<uuid_or_new>.<col>) ─────────────────────────────
  IF v_prefix = 'id' THEN
    DECLARE
      v_id_key text := v_parts[2];
      v_col    text := v_parts[3];
    BEGIN
      IF v_id_key = 'new' THEN
        v_target := (md5(p_employee_id::text || ':identity_pending'))::uuid;
        CASE v_col
          WHEN 'country'      THEN INSERT INTO identity_records (id, employee_id, country)      VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET country      = EXCLUDED.country;
          WHEN 'id_type'      THEN INSERT INTO identity_records (id, employee_id, id_type)      VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET id_type      = EXCLUDED.id_type;
          WHEN 'record_type'  THEN INSERT INTO identity_records (id, employee_id, record_type)  VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET record_type  = EXCLUDED.record_type;
          WHEN 'id_number'    THEN INSERT INTO identity_records (id, employee_id, id_number)    VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET id_number    = EXCLUDED.id_number;
          WHEN 'expiry'       THEN INSERT INTO identity_records (id, employee_id, expiry)       VALUES (v_target, p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (id) DO UPDATE SET expiry = EXCLUDED.expiry;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;
      ELSE
        v_target := v_id_key::uuid;
        CASE v_col
          WHEN 'country'     THEN UPDATE identity_records SET country     = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'id_type'     THEN UPDATE identity_records SET id_type     = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'record_type' THEN UPDATE identity_records SET record_type = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'expiry'      THEN UPDATE identity_records SET expiry      = NULLIF(p_new_value,'')::date WHERE id = v_target AND employee_id = p_employee_id;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;
      END IF;
      RETURN;
    END;
  END IF;

  -- ── All other fields ──────────────────────────────────────────────────────
  CASE p_field_key

    -- employees base table (no name — name is now computed from first+last)
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.dept_id'         THEN UPDATE employees SET dept_id        = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;
    WHEN 'emp.manager_id'      THEN UPDATE employees SET manager_id     = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;

    -- employee_personal — route through upsert_personal_info so name stays computed
    -- Uses hire_date as effective_from (same as AddEmployee saveExtendedData).
    WHEN 'personal.first_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('first_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.first_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.middle_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('middle_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.middle_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.last_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('last_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.last_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.nationality' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('nationality', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.nationality update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.gender' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('gender', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.gender update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.dob' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('dob', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.dob update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.marital_status' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('marital_status', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.marital_status update failed: %', v_pi_result->>'error';
      END IF;

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

    -- passports (upsert on employee_id)
    WHEN 'passport.country'         THEN INSERT INTO passports (employee_id, country)         VALUES (p_employee_id, p_new_value)                  ON CONFLICT (employee_id) DO UPDATE SET country         = EXCLUDED.country;
    WHEN 'passport.passport_number' THEN INSERT INTO passports (employee_id, passport_number) VALUES (p_employee_id, p_new_value)                  ON CONFLICT (employee_id) DO UPDATE SET passport_number = EXCLUDED.passport_number;
    WHEN 'passport.issue_date'      THEN INSERT INTO passports (employee_id, issue_date)      VALUES (p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (employee_id) DO UPDATE SET issue_date      = EXCLUDED.issue_date;
    WHEN 'passport.expiry_date'     THEN INSERT INTO passports (employee_id, expiry_date)     VALUES (p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (employee_id) DO UPDATE SET expiry_date     = EXCLUDED.expiry_date;

    -- emergency_contacts (upsert on employee_id — one row)
    WHEN 'ec.name'         THEN INSERT INTO emergency_contacts (employee_id, name)         VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET name         = EXCLUDED.name;
    WHEN 'ec.relationship' THEN INSERT INTO emergency_contacts (employee_id, relationship) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET relationship = EXCLUDED.relationship;
    WHEN 'ec.phone'        THEN INSERT INTO emergency_contacts (employee_id, phone)        VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET phone        = EXCLUDED.phone;
    WHEN 'ec.alt_phone'    THEN INSERT INTO emergency_contacts (employee_id, alt_phone)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET alt_phone    = EXCLUDED.alt_phone;
    WHEN 'ec.email'        THEN INSERT INTO emergency_contacts (employee_id, email)        VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET email        = EXCLUDED.email;

    -- Read-only / computed fields — silently ignore
    WHEN 'emp.employee_id', 'emp.status', 'emp.base_currency_id' THEN NULL;

    ELSE
      RAISE EXCEPTION 'Unknown field key: %', p_field_key
        USING ERRCODE = 'invalid_parameter_value';
  END CASE;
END;
$$;

REVOKE ALL     ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Update a single field on a hire-pipeline employee record. '
  'Field key format: <table_prefix>.<column> (e.g. personal.first_name, emp.hire_date). '
  'Mig 333: personal.* fields now route through upsert_personal_info (fixes broken '
  'ON CONFLICT after mig-315 multi-row conversion). Removed emp.name handler '
  '(name is now computed from first_name + middle_name + last_name). '
  'Added personal.first_name / personal.middle_name / personal.last_name.';
