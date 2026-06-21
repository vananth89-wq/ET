-- =============================================================================
-- Migration 298 — Fix dependent relationship label + hide dependent_code
-- =============================================================================
--
-- TWO ISSUES seen in UI after migration 297:
--
--   1. RELATIONSHIP shows raw code "DR002" instead of "Child"
--      Root cause: migration 297 still used `id::text = relationship_type`.
--      But relationship_type stores a ref_id code ("DR001"…"DR008"), NOT a UUID.
--      The correct lookup joins picklists to scope by DEPENDENT_RELATIONSHIP_TYPE
--      and matches on pv.ref_id = v_dep_rec.relationship_type.
--
--   2. DEPENDENT CODE row still visible in hire review panel
--      Root cause: edits to migration 297 removing dependent_code from the
--      jsonb_build_array were made after 297 had already been pushed to the DB.
--
-- FIX: Re-apply get_employee_hire_review with both corrections.
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

  v_bank_rec    employee_bank_accounts%ROWTYPE;
  v_bank_idx    int := 0;
  v_bank_label  text;

  v_dep_rec      employee_dependents%ROWTYPE;
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
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl,     '—'),'raw_value',v_id_country_raw,       'key',v_id_key_prefix||'.country',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,        '—'),'raw_value',v_id_type_raw,          'key',v_id_key_prefix||'.id_type',    'editable',true,'input_type','select','required',false),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,     '—'),'raw_value',v_id_rectype_raw,       'key',v_id_key_prefix||'.record_type','editable',true,'input_type','select','required',false),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,   '—'),'raw_value',v_id_rec.id_number,     'key',v_id_key_prefix||'.id_number',  'editable',true,'input_type','text',  'required',false),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text,  'key',v_id_key_prefix||'.expiry',     'editable',true,'input_type','date',  'required',false)
      )
    );
  END LOOP;

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

  -- ── Section 8: Bank Accounts (read-only) ─────────────────────────────────
  FOR v_bank_rec IN
    SELECT * FROM employee_bank_accounts
    WHERE  employee_id = p_employee_id
      AND  effective_to = '9999-12-31'::date
    ORDER  BY is_primary DESC, created_at
  LOOP
    v_bank_idx  := v_bank_idx + 1;
    v_bank_label := 'Bank Account ' || v_bank_idx
                 || CASE WHEN v_bank_rec.is_primary THEN ' (Primary)' ELSE '' END;

    v_result := v_result || jsonb_build_object(
      'section', v_bank_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Bank Name',      'value',COALESCE(v_bank_rec.bank_name,           '—'),'raw_value',v_bank_rec.bank_name,           'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Holder', 'value',COALESCE(v_bank_rec.account_holder_name, '—'),'raw_value',v_bank_rec.account_holder_name, 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Number', 'value',COALESCE(v_bank_rec.account_number,      '—'),'raw_value',v_bank_rec.account_number,      'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Country',        'value',COALESCE(v_bank_rec.country_code,        '—'),'raw_value',v_bank_rec.country_code,        'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Currency',       'value',COALESCE(v_bank_rec.currency_code,       '—'),'raw_value',v_bank_rec.currency_code,       'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Branch Name',    'value',COALESCE(v_bank_rec.branch_name,         '—'),'raw_value',v_bank_rec.branch_name,         'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','IFSC Code',      'value',COALESCE(v_bank_rec.ifsc_code,           '—'),'raw_value',v_bank_rec.ifsc_code,           'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','IBAN',           'value',COALESCE(v_bank_rec.iban,                '—'),'raw_value',v_bank_rec.iban,                'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Branch Code',    'value',COALESCE(v_bank_rec.branch_code,         '—'),'raw_value',v_bank_rec.branch_code,         'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Swift / BIC',    'value',COALESCE(v_bank_rec.swift_bic,           '—'),'raw_value',v_bank_rec.swift_bic,           'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Effective From', 'value',COALESCE(v_bank_rec.effective_from::text,'—'),'raw_value',v_bank_rec.effective_from::text,'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  IF v_bank_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Bank Account',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Bank Name',      'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Number', 'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false)
      )
    );
  END IF;

  -- ── Section 9: Dependents (read-only) ────────────────────────────────────
  -- relationship_type stores a ref_id code ("DR001"…"DR008"), NOT a UUID.
  -- Use picklists JOIN + ref_id match to resolve to the human-readable label.
  -- dependent_code is intentionally omitted — internal system field, not shown.
  FOR v_dep_rec IN
    SELECT * FROM employee_dependents
    WHERE  employee_id = p_employee_id
      AND  is_active   = true
      AND  effective_to = '9999-12-31'::date
    ORDER  BY effective_from, created_at
  LOOP
    v_dep_idx     := v_dep_idx + 1;
    v_dep_rel_lbl := NULL;

    IF v_dep_rec.relationship_type IS NOT NULL THEN
      SELECT pv.value INTO v_dep_rel_lbl
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'DEPENDENT_RELATIONSHIP_TYPE'
        AND  pv.ref_id      = v_dep_rec.relationship_type
      LIMIT 1;
      v_dep_rel_lbl := COALESCE(v_dep_rel_lbl, v_dep_rec.relationship_type);
    END IF;

    v_dep_label := 'Dependent ' || v_dep_idx
                || ' — ' || COALESCE(v_dep_rec.dependent_name, '');

    v_result := v_result || jsonb_build_object(
      'section', v_dep_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',           'value',COALESCE(v_dep_rec.dependent_name,                          '—'),'raw_value',v_dep_rec.dependent_name,         'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Relationship',   'value',COALESCE(v_dep_rel_lbl,                                     '—'),'raw_value',v_dep_rec.relationship_type,       'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Date of Birth',  'value',COALESCE(v_dep_rec.date_of_birth::text,                     '—'),'raw_value',v_dep_rec.date_of_birth::text,     'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Gender',         'value',COALESCE(v_dep_rec.gender,                                  '—'),'raw_value',v_dep_rec.gender,                  'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Insurance',      'value',CASE WHEN v_dep_rec.insurance_eligible THEN 'Yes' ELSE 'No' END,'raw_value',v_dep_rec.insurance_eligible::text,  'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Effective From', 'value',COALESCE(v_dep_rec.effective_from::text,                    '—'),'raw_value',v_dep_rec.effective_from::text,    'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  IF v_dep_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Dependent',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',         'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Relationship', 'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false)
      )
    );
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all hire sections as JSONB with full edit metadata. '
  'Section order: Personal Info, Contact, Employment, Identity Document(s), '
  'Passport, Address, Emergency Contact, Bank Account(s), Dependent(s). '
  'Mig 298: relationship resolved via ref_id lookup; dependent_code removed from output.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 298
-- =============================================================================
