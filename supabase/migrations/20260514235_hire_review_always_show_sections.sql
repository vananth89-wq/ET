-- =============================================================================
-- Migration 235: Always show all hire review sections
--
-- Changes:
--   1. get_employee_hire_review — removes IF NOT NULL guards so Address,
--      Passport, and Emergency Contact sections always appear (showing '—'
--      when the satellite row doesn't yet exist).
--
--   2. update_hire_field — upgrades passports and emergency_contacts from
--      plain UPDATE to INSERT … ON CONFLICT upsert so approvers can create
--      those rows when they fill in previously blank sections.
--
--   Requires UNIQUE(employee_id) on both tables (added below if absent).
-- =============================================================================

-- Ensure unique constraints exist so ON CONFLICT works.
-- Using IF NOT EXISTS pre-check avoids 42P07 (duplicate index name) errors.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'passports_employee_id_key'
      AND conrelid = 'passports'::regclass
  ) THEN
    ALTER TABLE passports ADD CONSTRAINT passports_employee_id_key UNIQUE (employee_id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'emergency_contacts_employee_id_key'
      AND conrelid = 'emergency_contacts'::regclass
  ) THEN
    ALTER TABLE emergency_contacts ADD CONSTRAINT emergency_contacts_employee_id_key UNIQUE (employee_id);
  END IF;
END $$;

-- =============================================================================
-- 1.  get_employee_hire_review — always return all sections
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

  v_nationality    text;
  v_marital_raw    text;
  v_gender         text;
  v_dob            date;

  v_contact    employee_contact%ROWTYPE;
  v_employment employee_employment%ROWTYPE;
  v_addr       employee_addresses%ROWTYPE;
  v_passport   passports%ROWTYPE;
  v_ec         emergency_contacts%ROWTYPE;

  v_dept                text;
  v_manager             text;
  v_currency            text;
  v_designation_label   text;
  v_work_country_label  text;
  v_work_location_label text;
  v_marital_label       text;

  v_id_rec          identity_records%ROWTYPE;
  v_id_idx          int := 0;
  v_id_country_raw  text;
  v_id_type_raw     text;
  v_id_rectype_raw  text;
  v_id_country_lbl  text;
  v_id_type_lbl     text;
  v_id_rectype_lbl  text;
  v_id_key_prefix   text;

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

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Employee ID',    'value',COALESCE(v_emp_id,        '—'),'raw_value',v_emp_id,       'key','emp.employee_id',        'editable',false,'input_type','readonly'),
      jsonb_build_object('label','Full Name',      'value',COALESCE(v_name,          '—'),'raw_value',v_name,         'key','emp.name',               'editable',true, 'input_type','text'),
      jsonb_build_object('label','Nationality',    'value',COALESCE(v_nationality,   '—'),'raw_value',v_nationality,  'key','personal.nationality',   'editable',true, 'input_type','select'),
      jsonb_build_object('label','Marital Status', 'value',COALESCE(v_marital_label, '—'),'raw_value',v_marital_raw,  'key','personal.marital_status','editable',true, 'input_type','select'),
      jsonb_build_object('label','Gender',         'value',COALESCE(v_gender,        '—'),'raw_value',v_gender,       'key','personal.gender',        'editable',true, 'input_type','select'),
      jsonb_build_object('label','Date of Birth',  'value',COALESCE(v_dob::text,     '—'),'raw_value',v_dob::text,    'key','personal.dob',           'editable',true, 'input_type','date'),
      jsonb_build_object('label','Status',         'value',COALESCE(v_status,        '—'),'raw_value',v_status,       'key','emp.status',             'editable',false,'input_type','readonly')
    )
  );

  -- ── Section 2: Contact ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Business Email','value',COALESCE(v_business_email,         '—'),'raw_value',v_business_email,           'key','emp.business_email',        'editable',true,'input_type','email'),
      jsonb_build_object('label','Personal Email','value',COALESCE(v_contact.personal_email, '—'),'raw_value',v_contact.personal_email,    'key','contact.personal_email',    'editable',true,'input_type','email'),
      jsonb_build_object('label','Mobile',        'value',COALESCE(
        NULLIF(CONCAT_WS(' ', v_contact.country_code, v_contact.mobile), ''), '—'
      ), 'raw_value',v_contact.mobile, 'key','contact.mobile', 'editable',true,'input_type','text')
    )
  );

  -- ── Section 3: Employment ─────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Designation',   'value',COALESCE(v_designation_label,                 '—'),'raw_value',v_designation,              'key','emp.designation',              'editable',true, 'input_type','select'),
      jsonb_build_object('label','Department',    'value',COALESCE(v_dept,                               '—'),'raw_value',v_dept_id::text,             'key','emp.dept_id',                  'editable',false,'input_type','readonly'),
      jsonb_build_object('label','Manager',       'value',COALESCE(v_manager,                            '—'),'raw_value',v_manager_id::text,          'key','emp.manager_id',               'editable',false,'input_type','readonly'),
      jsonb_build_object('label','Hire Date',     'value',COALESCE(v_hire_date::text,                    '—'),'raw_value',v_hire_date::text,           'key','emp.hire_date',                'editable',true, 'input_type','date'),
      jsonb_build_object('label','Probation End', 'value',COALESCE(v_employment.probation_end_date::text,'—'),'raw_value',v_employment.probation_end_date::text,'key','employment.probation_end_date','editable',true,'input_type','date'),
      jsonb_build_object('label','Work Country',  'value',COALESCE(v_work_country_label,                 '—'),'raw_value',v_work_country,             'key','emp.work_country',             'editable',true, 'input_type','select'),
      jsonb_build_object('label','Work Location', 'value',COALESCE(v_work_location_label,                '—'),'raw_value',v_work_location,            'key','emp.work_location',            'editable',true, 'input_type','select'),
      jsonb_build_object('label','Base Currency', 'value',COALESCE(v_currency,                           '—'),'raw_value',v_base_curr_id::text,       'key','emp.base_currency_id',         'editable',false,'input_type','readonly')
    )
  );

  -- ── Section 4: Address — always shown ────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Address',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Line 1',   'value',COALESCE(v_addr.line1,   '—'),'raw_value',v_addr.line1,   'key','addr.line1',   'editable',true,'input_type','text'),
      jsonb_build_object('label','Line 2',   'value',COALESCE(v_addr.line2,   '—'),'raw_value',v_addr.line2,   'key','addr.line2',   'editable',true,'input_type','text'),
      jsonb_build_object('label','Landmark', 'value',COALESCE(v_addr.landmark,'—'),'raw_value',v_addr.landmark,'key','addr.landmark','editable',true,'input_type','text'),
      jsonb_build_object('label','City',     'value',COALESCE(v_addr.city,    '—'),'raw_value',v_addr.city,    'key','addr.city',    'editable',true,'input_type','text'),
      jsonb_build_object('label','District', 'value',COALESCE(v_addr.district,'—'),'raw_value',v_addr.district,'key','addr.district','editable',true,'input_type','text'),
      jsonb_build_object('label','State',    'value',COALESCE(v_addr.state,   '—'),'raw_value',v_addr.state,   'key','addr.state',   'editable',true,'input_type','text'),
      jsonb_build_object('label','PIN',      'value',COALESCE(v_addr.pin,     '—'),'raw_value',v_addr.pin,     'key','addr.pin',     'editable',true,'input_type','text'),
      jsonb_build_object('label','Country',  'value',COALESCE(v_addr.country, '—'),'raw_value',v_addr.country, 'key','addr.country', 'editable',true,'input_type','text')
    )
  );

  -- ── Section 5: Passport — always shown ───────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Passport',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Country',         'value',COALESCE(v_passport.country,         '—'),'raw_value',v_passport.country,         'key','passport.country',         'editable',true,'input_type','text'),
      jsonb_build_object('label','Passport Number', 'value',COALESCE(v_passport.passport_number, '—'),'raw_value',v_passport.passport_number, 'key','passport.passport_number', 'editable',true,'input_type','text'),
      jsonb_build_object('label','Issue Date',      'value',COALESCE(v_passport.issue_date::text,'—'),'raw_value',v_passport.issue_date::text,'key','passport.issue_date',      'editable',true,'input_type','date'),
      jsonb_build_object('label','Expiry Date',     'value',COALESCE(v_passport.expiry_date::text,'—'),'raw_value',v_passport.expiry_date::text,'key','passport.expiry_date',   'editable',true,'input_type','date')
    )
  );

  -- ── Section 6: Emergency Contact — always shown ───────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Emergency Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Name',         'value',COALESCE(v_ec.name,        '—'),'raw_value',v_ec.name,        'key','ec.name',        'editable',true,'input_type','text'),
      jsonb_build_object('label','Relationship', 'value',COALESCE(v_ec.relationship,'—'),'raw_value',v_ec.relationship,'key','ec.relationship','editable',true,'input_type','text'),
      jsonb_build_object('label','Phone',        'value',COALESCE(v_ec.phone,       '—'),'raw_value',v_ec.phone,       'key','ec.phone',       'editable',true,'input_type','text'),
      jsonb_build_object('label','Alt Phone',    'value',COALESCE(v_ec.alt_phone,   '—'),'raw_value',v_ec.alt_phone,  'key','ec.alt_phone',   'editable',true,'input_type','text'),
      jsonb_build_object('label','Email',        'value',COALESCE(v_ec.email,       '—'),'raw_value',v_ec.email,      'key','ec.email',       'editable',true,'input_type','email')
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
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl, '—'),'raw_value',v_id_country_raw,'key',v_id_key_prefix||'.country',    'editable',true, 'input_type','select'),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,   '—'),'raw_value',v_id_type_raw,   'key',v_id_key_prefix||'.id_type',    'editable',true, 'input_type','select'),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,'—'),'raw_value',v_id_rectype_raw,'key',v_id_key_prefix||'.record_type','editable',true, 'input_type','select'),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,  '—'),'raw_value',v_id_rec.id_number,  'key',v_id_key_prefix||'.id_number','editable',true,'input_type','text'),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text,'key',v_id_key_prefix||'.expiry','editable',true,'input_type','date')
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all hire sections as JSONB. Address, Passport, and Emergency Contact '
  'are always included even when the satellite row is absent — approvers can fill '
  'in missing data directly from this page.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;


-- =============================================================================
-- 2.  update_hire_field — upsert for passports and emergency_contacts
-- =============================================================================

CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id uuid,
  p_field_key   text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parts     text[];
  v_record_id uuid;
  v_col       text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status = 'Pending'
  ) THEN
    RAISE EXCEPTION 'Employee % is not in Pending status — inline edit blocked.', p_employee_id;
  END IF;

  -- identity_records: key format  id.<uuid>.<column>
  IF p_field_key LIKE 'id.%.%' THEN
    v_parts     := string_to_array(p_field_key, '.');
    v_record_id := v_parts[2]::uuid;
    v_col       := v_parts[3];
    CASE v_col
      WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                    WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'expiry'      THEN UPDATE identity_records SET expiry       = NULLIF(p_new_value,'')::date   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'country'     THEN UPDATE identity_records SET country      = p_new_value                    WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'id_type'     THEN UPDATE identity_records SET id_type      = p_new_value                    WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'record_type' THEN UPDATE identity_records SET record_type  = p_new_value                    WHERE id = v_record_id AND employee_id = p_employee_id;
      ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
    END CASE;
    RETURN;
  END IF;

  CASE p_field_key

    -- employees
    WHEN 'emp.name'            THEN UPDATE employees SET name           = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;

    -- employee_personal
    WHEN 'personal.nationality' THEN
      INSERT INTO employee_personal (employee_id, nationality)
      VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET nationality = EXCLUDED.nationality;
    WHEN 'personal.gender' THEN
      INSERT INTO employee_personal (employee_id, gender)
      VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET gender = EXCLUDED.gender;
    WHEN 'personal.dob' THEN
      INSERT INTO employee_personal (employee_id, dob)
      VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET dob = EXCLUDED.dob;
    WHEN 'personal.marital_status' THEN
      INSERT INTO employee_personal (employee_id, marital_status)
      VALUES (p_employee_id, p_new_value)
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

    -- passports — upsert so approvers can create a row that doesn't exist yet
    WHEN 'passport.country'         THEN
      INSERT INTO passports (employee_id, country)         VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET country         = EXCLUDED.country;
    WHEN 'passport.passport_number' THEN
      INSERT INTO passports (employee_id, passport_number) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET passport_number = EXCLUDED.passport_number;
    WHEN 'passport.issue_date'      THEN
      INSERT INTO passports (employee_id, issue_date)      VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET issue_date      = EXCLUDED.issue_date;
    WHEN 'passport.expiry_date'     THEN
      INSERT INTO passports (employee_id, expiry_date)     VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET expiry_date     = EXCLUDED.expiry_date;

    -- emergency_contacts — upsert so approvers can create a row that doesn't exist yet
    WHEN 'ec.name'         THEN
      INSERT INTO emergency_contacts (employee_id, name)         VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET name         = EXCLUDED.name;
    WHEN 'ec.relationship' THEN
      INSERT INTO emergency_contacts (employee_id, relationship) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET relationship = EXCLUDED.relationship;
    WHEN 'ec.phone'        THEN
      INSERT INTO emergency_contacts (employee_id, phone)        VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET phone        = EXCLUDED.phone;
    WHEN 'ec.alt_phone'    THEN
      INSERT INTO emergency_contacts (employee_id, alt_phone)    VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET alt_phone    = EXCLUDED.alt_phone;
    WHEN 'ec.email'        THEN
      INSERT INTO emergency_contacts (employee_id, email)        VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET email        = EXCLUDED.email;

    ELSE RAISE EXCEPTION 'Unknown field key: %', p_field_key;
  END CASE;
END;
$$;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Routes a single-field hire review update to the correct satellite table. '
  'Passports and emergency_contacts now use INSERT ON CONFLICT upsert so '
  'approvers can populate sections that were left blank during onboarding.';

REVOKE ALL ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;
-- =============================================================================
-- END OF MIGRATION 235
-- =============================================================================
