-- =============================================================================
-- Migration 246: Split combined mobile field → separate Country Code + Mobile
--               in get_employee_hire_review + backfill existing records
--
-- BACKGROUND
-- ──────────
-- The Contact section of get_employee_hire_review currently renders the mobile
-- number as a single combined display field:
--
--   CONCAT_WS(' ', v_contact.country_code, v_contact.mobile)
--
-- This means the inline editor in WorkflowReview.tsx has no way to edit the
-- country code separately — the field is tagged input_type='text' and keyed to
-- 'contact.mobile', so the country code is silently dropped on save.
--
-- CHANGES
-- ───────
-- 1. get_employee_hire_review — Contact section:
--    Replace the single Mobile row with two rows:
--      a) Country Code  — input_type='phone_code', key='contact.country_code'
--      b) Mobile        — input_type='text',       key='contact.mobile'
--    WorkflowReview.tsx will render Country Code as a flag+code <select>
--    driven by the shared PHONE_CODES constant.
--
-- 2. Backfill employee_contact:
--    Some records were saved before the country_code column was tracked
--    separately — the dial prefix was embedded in the mobile column
--    (e.g. '+91 9876543210').  Extract and normalise these.
--
--    Condition:  country_code IS NULL
--            AND mobile LIKE '+%'      -- starts with a plus sign
--            AND mobile LIKE '% %'     -- has a space (prefix separator)
--
--    Action:
--      country_code = everything before the first space  (e.g. '+91')
--      mobile       = everything after  the first space  (e.g. '9876543210')
--
-- COMMENT UPDATE
-- ──────────────
-- Function comment updated to reflect new phone_code input type.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Backfill existing employee_contact records
--
-- Run BEFORE the function update so that if someone calls the function
-- immediately after migration the values are already clean.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE employee_contact
SET
  country_code = split_part(mobile, ' ', 1),
  mobile       = trim(substring(mobile FROM length(split_part(mobile, ' ', 1)) + 2))
WHERE country_code IS NULL
  AND mobile LIKE '+%'
  AND mobile LIKE '% %';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Update get_employee_hire_review — split Contact mobile field
-- ─────────────────────────────────────────────────────────────────────────────

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

  -- passport required only when a country is already recorded
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

  -- Passport sub-fields are required only when a passport country has been entered
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
  -- Country Code and Mobile are stored as separate columns in employee_contact
  -- and are now exposed as separate editable rows.
  -- Country Code uses input_type='phone_code' so WorkflowReview renders a
  -- flag+code <select> driven by the shared PHONE_CODES constant.
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
  'required=true mirrors AddEmployee.tsx validation rules. '
  'Mig 246: split combined mobile into Country Code (phone_code) + Mobile rows.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'get_employee_hire_review'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_employee_hire_review not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 246 verified: get_employee_hire_review present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 246
--
-- After this migration:
--   employee_contact  — backfilled: rows with embedded prefix in mobile are
--                       normalised (country_code set, prefix stripped from mobile)
--   get_employee_hire_review — Contact section now has 4 fields:
--     Business Email  (email)
--     Personal Email  (email)
--     Country Code    (phone_code) ← new; was part of combined Mobile display
--     Mobile          (text)       ← now stores bare number only
--
-- No schema changes.  No type regen needed.
-- WorkflowReview.tsx (Task #79) must add the phone_code case to its edit
-- control renderer to complete the feature.
-- =============================================================================
