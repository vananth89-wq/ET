-- Migration 264: identity_review_option_b
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEMS FIXED
-- ──────────────
-- Three separate bugs in the hire-review identity pipeline, all introduced or
-- exposed by mig 246 changing the identity field-key format:
--
-- BUG 1 — Identity section invisible to approver when no records exist
-- ────────────────────────────────────────────────────────────────────
-- get_employee_hire_review adds identity sections inside a FOR loop over
-- identity_records. When the employee has no identity records (v_id_idx = 0),
-- no section is appended. The approver sees Address and Passport but no
-- Identity Document section at all, and cannot add one.
--
-- BUG 2 — Existing identity-record edits silently update 0 rows
-- ──────────────────────────────────────────────────────────────
-- Mig 246 changed the identity key format from  id.<country>.<col>
--                                             to  id.<record_uuid>.<col>
--
-- update_hire_field's identity block (mig 242, carried forward through 244,
-- 263) still routes with:
--
--     v_country text := v_parts[2];     -- ← now a UUID, not a country code
--     WHERE employee_id = p_employee_id AND country = v_country
--
-- v_parts[2] is now a UUID string. The WHERE clause compares the country
-- column (e.g. 'IN') against a UUID string — no row matches. The UPDATE
-- silently affects 0 rows. No error is raised; the approver's edit is lost.
--
-- BUG 3 — 'country' column missing from the identity CASE
-- ────────────────────────────────────────────────────────
-- get_employee_hire_review exposes identity.country as an editable field.
-- update_hire_field's identity CASE handles: id_type, record_type, id_number,
-- expiry — but NOT country. Editing the Country field of any identity document
-- raises:
--
--     RAISE EXCEPTION 'Unknown identity_records column: country'
--
-- FIXES
-- ─────
-- 1. get_employee_hire_review — after the FOR loop:
--    If v_id_idx = 0, append ONE placeholder "Identity Document" section with
--    5 editable fields keyed  id.new.<col>.  This lets approvers fill in
--    identity information for employees who didn't provide it.
--
-- 2. update_hire_field — identity routing block:
--    Replace the broken country-based WHERE with id-based routing.
--    Parse v_parts[2] as either 'new' (placeholder record) or a real UUID.
--
--    • 'new' path: UPSERT a row whose id is a deterministic UUID derived from
--      the employee UUID. This ensures all field saves for the placeholder
--      converge on the same row regardless of save order.
--      Derivation: format md5(p_employee_id::text || ':identity_pending') as UUID.
--
--    • UUID path: UPDATE WHERE id = v_parts[2]::uuid AND employee_id = …
--      (employee_id guard prevents cross-employee tampering).
--
-- 3. update_hire_field — 'country' added to the identity CASE (both paths).
--
-- ─────────────────────────────────────────────────────────────────────────────


-- ── Step 1: get_employee_hire_review — always show identity section ───────────

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

  -- ── Section 4: Identity Documents ───────────────────────────────────────
  -- Iterate existing records (keyed by record UUID, introduced in mig 246).
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
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl,     '—'),'raw_value',v_id_country_raw,       'key',v_id_key_prefix||'.country',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,        '—'),'raw_value',v_id_type_raw,          'key',v_id_key_prefix||'.id_type',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,     '—'),'raw_value',v_id_rectype_raw,       'key',v_id_key_prefix||'.record_type','editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,   '—'),'raw_value',v_id_rec.id_number,     'key',v_id_key_prefix||'.id_number',  'editable',true,'input_type','text',  'required',false),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text,  'key',v_id_key_prefix||'.expiry',     'editable',true,'input_type','date',  'required',false)
      )
    );
  END LOOP;

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

  -- ── Section 6: Address ───────────────────────────────────────────────────
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

  -- ── Section 7: Emergency Contact ─────────────────────────────────────────
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

  -- ── Option B: placeholder section when no identity records exist ──────────
  -- Keyed with 'id.new.<col>' so update_hire_field can route them to an
  -- UPSERT on a deterministic pending-record UUID for this employee.
  -- This allows approvers to add identity information that was not provided
  -- during onboarding.
  IF v_id_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',     'value','—','raw_value',NULL::text,'key','id.new.country',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Type',     'value','—','raw_value',NULL::text,'key','id.new.id_type',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','Record Type', 'value','—','raw_value',NULL::text,'key','id.new.record_type','editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Number',   'value','—','raw_value',NULL::text,'key','id.new.id_number',  'editable',true,'input_type','text',  'required',false),
        jsonb_build_object('label','Expiry',      'value','—','raw_value',NULL::text,'key','id.new.expiry',     'editable',true,'input_type','date',  'required',false)
      )
    );
  END IF;

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
  'Mig 246: split combined mobile into Country Code (phone_code) + Mobile rows. '
  'Mig 264: Option B — always show Identity Document section; placeholder uses '
  'id.new.* keys when no identity records exist so approvers can add them. '
  'Existing records keyed id.<record_uuid>.* (unchanged from mig 246).';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;


-- ── Step 2: update_hire_field — fix identity routing + add country + new path ─
--
-- Replaces the identity block introduced in mig 242 (carried through 244, 263).
-- Full function rewrite based on mig 263 with identity block replaced.

CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id uuid,
  p_field_key   text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_employee_uuid uuid := p_employee_id;
BEGIN
  -- ── Access guard ─────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'awaiting_clarification'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION 'Not authorised to edit hire field for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Only operate on Pending records ──────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status = 'Pending'
  ) THEN
    RAISE EXCEPTION 'update_hire_field: employee % is not in Pending status.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Identity records: routed by key pattern id.<rec_id_or_new>.<column> ──
  --
  -- Key format (mig 246+):  id.<record_uuid>.<col>   — edit existing record
  --                         id.new.<col>             — add to placeholder record
  --
  -- 'new' path: UPSERTs a row with a deterministic UUID derived from the
  -- employee UUID so all field saves for the placeholder converge on one row.
  -- Existing-record path: routes by record id, with employee_id guard.
  IF p_field_key LIKE 'id.%.%' THEN
    DECLARE
      v_parts    text[] := string_to_array(p_field_key, '.');
      v_rec_key  text   := v_parts[2];   -- 'new' or a UUID string
      v_col      text   := v_parts[3];
      v_target   uuid;
    BEGIN
      IF v_rec_key = 'new' THEN
        -- Derive a deterministic pending-record UUID from the employee UUID.
        -- md5() returns 32 hex chars; we format them as a UUID string.
        v_target := (
          left(   md5(p_employee_id::text || ':identity_pending'), 8) || '-' ||
          substr(  md5(p_employee_id::text || ':identity_pending'), 9,  4) || '-' ||
          substr(  md5(p_employee_id::text || ':identity_pending'), 13, 4) || '-' ||
          substr(  md5(p_employee_id::text || ':identity_pending'), 17, 4) || '-' ||
          substr(  md5(p_employee_id::text || ':identity_pending'), 21, 12)
        )::uuid;

        -- Ensure the row exists before we UPDATE it.
        INSERT INTO identity_records (id, employee_id)
        VALUES (v_target, p_employee_id)
        ON CONFLICT (id) DO NOTHING;

        CASE v_col
          WHEN 'country'     THEN UPDATE identity_records SET country     = p_new_value                  WHERE id = v_target;
          WHEN 'id_type'     THEN UPDATE identity_records SET id_type     = p_new_value                  WHERE id = v_target;
          WHEN 'record_type' THEN UPDATE identity_records SET record_type = p_new_value                  WHERE id = v_target;
          WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                  WHERE id = v_target;
          WHEN 'expiry'      THEN UPDATE identity_records SET expiry      = NULLIF(p_new_value,'')::date WHERE id = v_target;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;

      ELSE
        -- Existing record: route by record UUID (v_parts[2]).
        -- employee_id guard prevents cross-employee tampering.
        v_target := v_rec_key::uuid;

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

    -- employees base table
    WHEN 'emp.name'            THEN UPDATE employees SET name           = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.dept_id'         THEN UPDATE employees SET dept_id        = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;
    WHEN 'emp.manager_id'      THEN UPDATE employees SET manager_id     = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;

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
    WHEN 'passport.country'         THEN UPDATE passports SET country         = p_new_value                  WHERE employee_id = p_employee_id;
    WHEN 'passport.passport_number' THEN UPDATE passports SET passport_number = p_new_value                  WHERE employee_id = p_employee_id;
    WHEN 'passport.issue_date'      THEN UPDATE passports SET issue_date      = NULLIF(p_new_value,'')::date WHERE employee_id = p_employee_id;
    WHEN 'passport.expiry_date'     THEN UPDATE passports SET expiry_date     = NULLIF(p_new_value,'')::date WHERE employee_id = p_employee_id;

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
  'Inline-edit RPC for hire review. Callers must be either the workflow '
  'submitter (initiator editing a sent-back record) or pass '
  'user_can(hire_employee, edit, NULL) (approver mid-flight edit). '
  'Only operates on Pending employees. '
  'Mig 263: added emp.dept_id and emp.manager_id CASE branches. '
  'Mig 264: rewrote identity routing. '
  '  • id.<uuid>.<col> — UPDATE existing record WHERE id = uuid AND employee_id = … '
  '  • id.new.<col>    — UPSERT deterministic pending row (md5-derived UUID), '
  '                      then UPDATE specified column. All five columns now '
  '                      handled: country, id_type, record_type, id_number, expiry. '
  'Fixes three bugs: (1) wrong WHERE clause (country vs UUID), '
  '(2) missing country column in CASE, (3) no INSERT path for new records.';

REVOKE ALL   ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'get_employee_hire_review'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_employee_hire_review not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'update_hire_field'
  ) THEN
    RAISE EXCEPTION 'ABORT: update_hire_field not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 264 verified: get_employee_hire_review (Option B placeholder) and update_hire_field (UUID identity routing) both present.';
END;
$$;
