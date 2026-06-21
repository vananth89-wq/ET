-- =============================================================================
-- Migration 231: get_employee_hire_review — add field metadata (key, editable)
--
-- Each field in the JSONB array gains two new properties:
--   "key"      — dot-notation identifier used by update_hire_field() to route
--                the update to the correct table/column.
--                Format: "<table_prefix>.<column>"
--                Identity records use:  "id.<record_uuid>.<column>"
--   "editable" — boolean; false for read-only fields (picklists, FK lookups,
--                workflow-controlled status, composite mobile display field).
--
-- Picklist / FK fields are marked editable=false because the raw UUID stored
-- in the DB cannot be meaningfully edited with a plain text input; they
-- require the full AddEmployee edit flow (Update button).
--
-- NOTE: The identity_records key uses the record's UUID so update_hire_field
-- can target the exact row.  The table MUST have a UUID primary key column
-- named "id" (standard Supabase convention).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_hire_review(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Core employee columns
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

  -- employee_personal — explicit scalars
  v_nationality    text;
  v_marital_raw    text;
  v_gender         text;
  v_dob            date;

  -- Other satellite rows
  v_contact    employee_contact%ROWTYPE;
  v_employment employee_employment%ROWTYPE;
  v_addr       employee_addresses%ROWTYPE;
  v_passport   passports%ROWTYPE;
  v_ec         emergency_contacts%ROWTYPE;

  -- Resolved labels
  v_dept                text;
  v_manager             text;
  v_currency            text;
  v_designation_label   text;
  v_work_country_label  text;
  v_work_location_label text;
  v_marital_label       text;

  -- Identity records loop
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
  -- ── Fetch core employee row ───────────────────────────────────────────────
  SELECT
    employee_id, name, business_email, designation,
    dept_id, manager_id, hire_date, end_date,
    work_country, work_location, base_currency_id, status::text
  INTO
    v_emp_id, v_name, v_business_email, v_designation,
    v_dept_id, v_manager_id, v_hire_date, v_end_date,
    v_work_country, v_work_location, v_base_curr_id, v_status
  FROM employees
  WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  -- ── Resolve FK labels ─────────────────────────────────────────────────────
  SELECT name INTO v_dept    FROM departments WHERE id = v_dept_id;
  SELECT name INTO v_manager FROM employees   WHERE id = v_manager_id;
  SELECT code INTO v_currency FROM currencies WHERE id = v_base_curr_id;

  -- ── Resolve picklist UUIDs on employees ──────────────────────────────────
  SELECT value INTO v_designation_label
  FROM   picklist_values WHERE id::text = v_designation LIMIT 1;
  v_designation_label := COALESCE(v_designation_label, v_designation);

  SELECT value INTO v_work_country_label
  FROM   picklist_values WHERE id::text = v_work_country LIMIT 1;
  v_work_country_label := COALESCE(v_work_country_label, v_work_country);

  SELECT value INTO v_work_location_label
  FROM   picklist_values WHERE id::text = v_work_location LIMIT 1;
  v_work_location_label := COALESCE(v_work_location_label, v_work_location);

  -- ── employee_personal — explicit column SELECT ────────────────────────────
  SELECT nationality, marital_status, gender, dob
  INTO   v_nationality, v_marital_raw, v_gender, v_dob
  FROM   employee_personal
  WHERE  employee_id = p_employee_id;

  IF v_marital_raw IS NOT NULL THEN
    SELECT value INTO v_marital_label
    FROM   picklist_values WHERE id::text = v_marital_raw LIMIT 1;
    v_marital_label := COALESCE(v_marital_label, v_marital_raw);
  END IF;

  -- ── Other satellite rows ──────────────────────────────────────────────────
  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id;
  SELECT * INTO v_employment FROM employee_employment WHERE employee_id = p_employee_id;
  SELECT * INTO v_addr       FROM employee_addresses  WHERE employee_id = p_employee_id;
  SELECT * INTO v_passport   FROM passports           WHERE employee_id = p_employee_id;
  SELECT * INTO v_ec         FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Employee ID',    'value',COALESCE(v_emp_id,        '—'),'key','emp.employee_id',        'editable',false),
      jsonb_build_object('label','Full Name',      'value',COALESCE(v_name,          '—'),'key','emp.name',               'editable',true),
      jsonb_build_object('label','Nationality',    'value',COALESCE(v_nationality,   '—'),'key','personal.nationality',   'editable',true),
      jsonb_build_object('label','Marital Status', 'value',COALESCE(v_marital_label, '—'),'key','personal.marital_status','editable',false),
      jsonb_build_object('label','Gender',         'value',COALESCE(v_gender,        '—'),'key','personal.gender',        'editable',true),
      jsonb_build_object('label','Date of Birth',  'value',COALESCE(v_dob::text,     '—'),'key','personal.dob',           'editable',true),
      jsonb_build_object('label','Status',         'value',COALESCE(v_status,        '—'),'key','emp.status',             'editable',false)
    )
  );

  -- ── Section 2: Contact ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Business Email','value',COALESCE(v_business_email,       '—'),'key','emp.business_email',        'editable',true),
      jsonb_build_object('label','Personal Email','value',COALESCE(v_contact.personal_email,'—'),'key','contact.personal_email',    'editable',true),
      jsonb_build_object('label','Mobile',        'value',COALESCE(
        NULLIF(CONCAT_WS(' ', v_contact.country_code, v_contact.mobile), ''), '—'
      ),                                                              'key','contact.mobile','editable',true)
    )
  );

  -- ── Section 3: Employment ─────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Designation',   'value',COALESCE(v_designation_label,                  '—'),'key','emp.designation',              'editable',false),
      jsonb_build_object('label','Department',    'value',COALESCE(v_dept,                                '—'),'key','emp.dept_id',                  'editable',false),
      jsonb_build_object('label','Manager',       'value',COALESCE(v_manager,                             '—'),'key','emp.manager_id',               'editable',false),
      jsonb_build_object('label','Hire Date',     'value',COALESCE(v_hire_date::text,                     '—'),'key','emp.hire_date',                'editable',true),
      jsonb_build_object('label','Probation End', 'value',COALESCE(v_employment.probation_end_date::text, '—'),'key','employment.probation_end_date', 'editable',true),
      jsonb_build_object('label','Work Country',  'value',COALESCE(v_work_country_label,                  '—'),'key','emp.work_country',             'editable',false),
      jsonb_build_object('label','Work Location', 'value',COALESCE(v_work_location_label,                 '—'),'key','emp.work_location',            'editable',false),
      jsonb_build_object('label','Base Currency', 'value',COALESCE(v_currency,                            '—'),'key','emp.base_currency_id',         'editable',false)
    )
  );

  -- ── Section 4: Address ────────────────────────────────────────────────────
  IF v_addr IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Address',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Line 1',   'value',COALESCE(v_addr.line1,    '—'),'key','addr.line1',    'editable',true),
        jsonb_build_object('label','Line 2',   'value',COALESCE(v_addr.line2,    '—'),'key','addr.line2',    'editable',true),
        jsonb_build_object('label','Landmark', 'value',COALESCE(v_addr.landmark, '—'),'key','addr.landmark', 'editable',true),
        jsonb_build_object('label','City',     'value',COALESCE(v_addr.city,     '—'),'key','addr.city',     'editable',true),
        jsonb_build_object('label','District', 'value',COALESCE(v_addr.district, '—'),'key','addr.district', 'editable',true),
        jsonb_build_object('label','State',    'value',COALESCE(v_addr.state,    '—'),'key','addr.state',    'editable',true),
        jsonb_build_object('label','PIN',      'value',COALESCE(v_addr.pin,      '—'),'key','addr.pin',      'editable',true),
        jsonb_build_object('label','Country',  'value',COALESCE(v_addr.country,  '—'),'key','addr.country',  'editable',true)
      )
    );
  END IF;

  -- ── Section 5: Passport ───────────────────────────────────────────────────
  IF v_passport IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Passport',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',         'value',COALESCE(v_passport.country,          '—'),'key','passport.country',         'editable',true),
        jsonb_build_object('label','Passport Number', 'value',COALESCE(v_passport.passport_number,  '—'),'key','passport.passport_number', 'editable',true),
        jsonb_build_object('label','Issue Date',      'value',COALESCE(v_passport.issue_date::text, '—'),'key','passport.issue_date',      'editable',true),
        jsonb_build_object('label','Expiry Date',     'value',COALESCE(v_passport.expiry_date::text,'—'),'key','passport.expiry_date',     'editable',true)
      )
    );
  END IF;

  -- ── Section 6: Emergency Contact ──────────────────────────────────────────
  IF v_ec IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Emergency Contact',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',         'value',COALESCE(v_ec.name,         '—'),'key','ec.name',         'editable',true),
        jsonb_build_object('label','Relationship', 'value',COALESCE(v_ec.relationship, '—'),'key','ec.relationship', 'editable',true),
        jsonb_build_object('label','Phone',        'value',COALESCE(v_ec.phone,        '—'),'key','ec.phone',        'editable',true),
        jsonb_build_object('label','Alt Phone',    'value',COALESCE(v_ec.alt_phone,    '—'),'key','ec.alt_phone',    'editable',true),
        jsonb_build_object('label','Email',        'value',COALESCE(v_ec.email,        '—'),'key','ec.email',        'editable',true)
      )
    );
  END IF;

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

    SELECT value INTO v_id_country_lbl
    FROM   picklist_values WHERE id::text = v_id_country_raw LIMIT 1;
    v_id_country_lbl := COALESCE(v_id_country_lbl, v_id_country_raw);

    SELECT value INTO v_id_type_lbl
    FROM   picklist_values WHERE id::text = v_id_type_raw LIMIT 1;
    v_id_type_lbl := COALESCE(v_id_type_lbl, v_id_type_raw);

    SELECT value INTO v_id_rectype_lbl
    FROM   picklist_values WHERE id::text = v_id_rectype_raw LIMIT 1;
    v_id_rectype_lbl := COALESCE(v_id_rectype_lbl, v_id_rectype_raw);

    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document ' || v_id_idx,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl,     '—'),'key',v_id_key_prefix||'.country',     'editable',false),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,        '—'),'key',v_id_key_prefix||'.id_type',     'editable',false),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,     '—'),'key',v_id_key_prefix||'.record_type', 'editable',false),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,   '—'),'key',v_id_key_prefix||'.id_number',   'editable',true),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'key',v_id_key_prefix||'.expiry',      'editable',true)
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all employee sections as JSONB [{section, fields:[{label,value,key,editable}]}]. '
  'key is a dot-notation field identifier used by update_hire_field(). '
  'editable=false for picklist/FK fields that require the full edit form.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 231
-- =============================================================================
