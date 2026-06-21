-- =============================================================================
-- Migration 295: Add Dependents section to get_employee_hire_review
--
-- The hire review RPC previously returned 8 sections:
--   Personal Info, Contact, Employment, Identity Document(s),
--   Passport, Address, Emergency Contact, Bank Account(s)
--
-- This migration adds Section 9: Dependent(s).
-- Dependents are always read-only in the hire review context — the approver
-- sees what the new hire submitted in AddEmployee Section 10.
--
-- One "Dependent N" section is emitted per active dependent (effective_to =
-- '9999-12-31', is_active = true). If no dependents exist a single placeholder
-- section is shown so the approver knows the section was skipped.
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

  -- Bank account loop variables
  v_bank_rec    employee_bank_accounts%ROWTYPE;
  v_bank_idx    int := 0;
  v_bank_label  text;

  -- Dependent loop variables
  v_dep_rec    employee_dependents%ROWTYPE;
  v_dep_idx    int := 0;
  v_dep_label  text;
  v_dep_rel_lbl text;

  v_result   jsonb := '[]'::jsonb;
BEGIN
  SELECT
    employee_id, name, business_email, designation,
    dept_id, manager_id, hire_date, end_date,
    work_country, work_location, base_currency_id, status
  INTO
    v_emp_id, v_name, v_business_email, v_designation,
    v_dept_id, v_manager_id, v_hire_date, v_end_date,
    v_work_country, v_work_location, v_base_curr_id, v_status
  FROM employees WHERE id = p_employee_id;

  SELECT full_name   INTO v_nationality      FROM picklist_values WHERE id::text = (SELECT nationality FROM employee_personal WHERE employee_id = p_employee_id LIMIT 1);
  SELECT raw_value   INTO v_marital_raw      FROM (SELECT marital_status AS raw_value FROM employee_personal WHERE employee_id = p_employee_id LIMIT 1) x;
  SELECT full_name   INTO v_marital_label    FROM picklist_values WHERE picklistId = 'MARITAL_STATUS' AND value = v_marital_raw LIMIT 1;
  SELECT gender      INTO v_gender           FROM employee_personal WHERE employee_id = p_employee_id LIMIT 1;
  SELECT date_of_birth INTO v_dob            FROM employee_personal WHERE employee_id = p_employee_id LIMIT 1;

  SELECT name INTO v_dept     FROM departments WHERE id = v_dept_id;
  SELECT name INTO v_manager  FROM employees   WHERE id = v_manager_id;
  SELECT code INTO v_currency FROM picklist_values WHERE id = v_base_curr_id;

  SELECT full_name INTO v_designation_label    FROM picklist_values WHERE picklistId = 'JOB_TITLE'       AND value = v_designation  LIMIT 1;
  SELECT full_name INTO v_work_country_label   FROM picklist_values WHERE picklistId = 'ID_COUNTRY'      AND value = v_work_country LIMIT 1;
  SELECT full_name INTO v_work_location_label  FROM picklist_values WHERE picklistId = 'WORK_LOCATION'   AND value = v_work_location LIMIT 1;

  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id LIMIT 1;
  SELECT * INTO v_employment FROM employee_employment WHERE employee_id = p_employee_id LIMIT 1;
  SELECT * INTO v_addr       FROM employee_addresses  WHERE employee_id = p_employee_id LIMIT 1;
  SELECT * INTO v_passport   FROM passports           WHERE employee_id = p_employee_id LIMIT 1;
  SELECT * INTO v_ec         FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  SELECT full_name INTO v_passport_country_lbl  FROM picklist_values WHERE picklistId = 'ID_COUNTRY' AND value = v_passport.country  LIMIT 1;
  SELECT full_name INTO v_ec_relationship_lbl   FROM picklist_values WHERE picklistId = 'EMERGENCY_CONTACT_RELATIONSHIP' AND value = v_ec.relationship LIMIT 1;

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Full Name',       'value',COALESCE(v_name,                               '—'),'raw_value',v_name,                'key','name',               'editable',true, 'input_type','text',     'required',true),
      jsonb_build_object('label','Employee ID',     'value',COALESCE(v_emp_id,                             '—'),'raw_value',v_emp_id,              'key','employee_id',        'editable',true, 'input_type','text',     'required',true),
      jsonb_build_object('label','Gender',          'value',COALESCE(v_gender,                             '—'),'raw_value',v_gender,              'key','pers.gender',        'editable',true, 'input_type','select',   'required',true,  'options',jsonb_build_array('Male','Female','Other')),
      jsonb_build_object('label','Date of Birth',   'value',COALESCE(to_char(v_dob,'DD Mon YYYY'),         '—'),'raw_value',v_dob::text,           'key','pers.dob',           'editable',true, 'input_type','date',     'required',true),
      jsonb_build_object('label','Nationality',     'value',COALESCE(v_nationality,                        '—'),'raw_value',(SELECT nationality FROM employee_personal WHERE employee_id = p_employee_id LIMIT 1),'key','pers.nationality','editable',true,'input_type','picklist','required',true,'picklist_id','ID_COUNTRY'),
      jsonb_build_object('label','Marital Status',  'value',COALESCE(v_marital_label, v_marital_raw,       '—'),'raw_value',v_marital_raw,         'key','pers.marital_status','editable',true, 'input_type','picklist', 'required',true,  'picklist_id','MARITAL_STATUS')
    )
  );

  -- ── Section 2: Contact ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Country Code', 'value',COALESCE(v_contact.country_code,'—'),'raw_value',v_contact.country_code,'key','contact.country_code','editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Mobile',       'value',COALESCE(v_contact.mobile,      '—'),'raw_value',v_contact.mobile,      'key','contact.mobile',      'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Personal Email','value',COALESCE(v_contact.personal_email,'—'),'raw_value',v_contact.personal_email,'key','contact.personal_email','editable',true,'input_type','email','required',false)
    )
  );

  -- ── Section 3: Business Email ─────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Business Email',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Business Email','value',COALESCE(v_business_email,'—'),'raw_value',v_business_email,'key','business_email','editable',true,'input_type','email','required',true)
    )
  );

  -- ── Section 4: Employment ─────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Department',        'value',COALESCE(v_dept,                           '—'),'raw_value',v_dept_id::text,         'key','dept_id',                'editable',true, 'input_type','select',   'required',true),
      jsonb_build_object('label','Manager',           'value',COALESCE(v_manager,                        '—'),'raw_value',v_manager_id::text,      'key','manager_id',             'editable',true, 'input_type','select',   'required',false),
      jsonb_build_object('label','Hire Date',         'value',COALESCE(to_char(v_hire_date,'DD Mon YYYY'),'—'),'raw_value',v_hire_date::text,      'key','hire_date',              'editable',true, 'input_type','date',     'required',true),
      jsonb_build_object('label','End Date',          'value',COALESCE(to_char(v_end_date,'DD Mon YYYY'),'—'),'raw_value',v_end_date::text,        'key','end_date',               'editable',true, 'input_type','date',     'required',false),
      jsonb_build_object('label','Job Title',         'value',COALESCE(v_designation_label,v_designation,'—'),'raw_value',v_designation,          'key','designation',            'editable',true, 'input_type','picklist', 'required',true,  'picklist_id','JOB_TITLE'),
      jsonb_build_object('label','Work Country',      'value',COALESCE(v_work_country_label,v_work_country,'—'),'raw_value',v_work_country,       'key','work_country',           'editable',true, 'input_type','picklist', 'required',true,  'picklist_id','ID_COUNTRY'),
      jsonb_build_object('label','Work Location',     'value',COALESCE(v_work_location_label,v_work_location,'—'),'raw_value',v_work_location,    'key','work_location',          'editable',true, 'input_type','picklist', 'required',false, 'picklist_id','WORK_LOCATION'),
      jsonb_build_object('label','Base Currency',     'value',COALESCE(v_currency,                       '—'),'raw_value',v_base_curr_id::text,   'key','base_currency_id',       'editable',true, 'input_type','select',   'required',false),
      jsonb_build_object('label','Employment Type',   'value',COALESCE(v_employment.employment_type,     '—'),'raw_value',v_employment.employment_type,'key','emp.employment_type','editable',true,'input_type','picklist','required',true,'picklist_id','EMPLOYMENT_TYPE'),
      jsonb_build_object('label','Contract Type',     'value',COALESCE(v_employment.contract_type,       '—'),'raw_value',v_employment.contract_type,  'key','emp.contract_type',  'editable',true,'input_type','picklist','required',false,'picklist_id','CONTRACT_TYPE'),
      jsonb_build_object('label','Probation End',     'value',COALESCE(to_char(v_employment.probation_end_date,'DD Mon YYYY'),'—'),'raw_value',v_employment.probation_end_date::text,'key','emp.probation_end_date','editable',true,'input_type','date','required',false)
    )
  );

  -- ── Section 5: Identity Documents (one section per record) ────────────────
  FOR v_id_rec IN
    SELECT * FROM identity_records
    WHERE  employee_id = p_employee_id
    ORDER  BY created_at
  LOOP
    v_id_idx        := v_id_idx + 1;
    v_id_key_prefix := 'id.' || v_id_rec.id::text;
    v_id_country_raw  := v_id_rec.country;
    v_id_type_raw     := v_id_rec.id_type;
    v_id_rectype_raw  := v_id_rec.record_type;
    SELECT full_name INTO v_id_country_lbl FROM picklist_values WHERE picklistId = 'ID_COUNTRY'   AND value = v_id_country_raw LIMIT 1;
    SELECT full_name INTO v_id_type_lbl    FROM picklist_values WHERE picklistId = 'ID_TYPE'      AND value = v_id_type_raw    LIMIT 1;
    SELECT full_name INTO v_id_rectype_lbl FROM picklist_values WHERE picklistId = 'ID_RECORD_TYPE' AND value = v_id_rectype_raw LIMIT 1;

    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document ' || v_id_idx,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',      'value',COALESCE(v_id_country_lbl, v_id_country_raw,'—'),'raw_value',v_id_country_raw,'key',v_id_key_prefix||'.country',    'editable',true,'input_type','picklist','required',true, 'picklist_id','ID_COUNTRY'),
        jsonb_build_object('label','ID Type',      'value',COALESCE(v_id_type_lbl,    v_id_type_raw,   '—'),'raw_value',v_id_type_raw,   'key',v_id_key_prefix||'.id_type',    'editable',true,'input_type','picklist','required',true, 'picklist_id','ID_TYPE'),
        jsonb_build_object('label','Record Type',  'value',COALESCE(v_id_rectype_lbl, v_id_rectype_raw,'—'),'raw_value',v_id_rectype_raw,'key',v_id_key_prefix||'.record_type','editable',true,'input_type','picklist','required',true, 'picklist_id','ID_RECORD_TYPE'),
        jsonb_build_object('label','ID Number',    'value',COALESCE(v_id_rec.id_number,               '—'),'raw_value',v_id_rec.id_number,   'key',v_id_key_prefix||'.id_number','editable',true,'input_type','text',   'required',true),
        jsonb_build_object('label','Expiry Date',  'value',COALESCE(to_char(v_id_rec.expiry_date,'DD Mon YYYY'),'—'),'raw_value',v_id_rec.expiry_date::text,'key',v_id_key_prefix||'.expiry','editable',true,'input_type','date','required',false)
      )
    );
  END LOOP;

  -- Placeholder when no identity records submitted
  IF v_id_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',   'value','—','raw_value',NULL::text,'key','id.new.country',    'editable',true,'input_type','picklist','required',true,'picklist_id','ID_COUNTRY'),
        jsonb_build_object('label','ID Type',   'value','—','raw_value',NULL::text,'key','id.new.id_type',    'editable',true,'input_type','picklist','required',true,'picklist_id','ID_TYPE'),
        jsonb_build_object('label','Record Type','value','—','raw_value',NULL::text,'key','id.new.record_type','editable',true,'input_type','picklist','required',true,'picklist_id','ID_RECORD_TYPE'),
        jsonb_build_object('label','ID Number', 'value','—','raw_value',NULL::text,'key','id.new.id_number',  'editable',true,'input_type','text',    'required',true)
      )
    );
  END IF;

  -- ── Section 6: Passport ───────────────────────────────────────────────────
  v_passport_required := (v_passport.passport_number IS NOT NULL AND v_passport.passport_number <> '');
  v_result := v_result || jsonb_build_object(
    'section', 'Passport',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Country',      'value',COALESCE(v_passport_country_lbl,v_passport.country,'—'),'raw_value',v_passport.country,          'key','pass.country',         'editable',true,'input_type','picklist','required',v_passport_required,'picklist_id','ID_COUNTRY'),
      jsonb_build_object('label','Passport No.', 'value',COALESCE(v_passport.passport_number,               '—'),'raw_value',v_passport.passport_number,  'key','pass.passport_number', 'editable',true,'input_type','text',    'required',false),
      jsonb_build_object('label','Issue Date',   'value',COALESCE(to_char(v_passport.issue_date,'DD Mon YYYY'),'—'),'raw_value',v_passport.issue_date::text,'key','pass.issue_date',    'editable',true,'input_type','date',    'required',v_passport_required),
      jsonb_build_object('label','Expiry Date',  'value',COALESCE(to_char(v_passport.expiry_date,'DD Mon YYYY'),'—'),'raw_value',v_passport.expiry_date::text,'key','pass.expiry_date','editable',true,'input_type','date',    'required',v_passport_required)
    )
  );

  -- ── Section 7: Address ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Address',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Address Line 1','value',COALESCE(v_addr.line1,   '—'),'raw_value',v_addr.line1,   'key','addr.line1',   'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Address Line 2','value',COALESCE(v_addr.line2,   '—'),'raw_value',v_addr.line2,   'key','addr.line2',   'editable',true,'input_type','text','required',false),
      jsonb_build_object('label','Landmark',      'value',COALESCE(v_addr.landmark,'—'),'raw_value',v_addr.landmark,'key','addr.landmark','editable',true,'input_type','text','required',false),
      jsonb_build_object('label','City',          'value',COALESCE(v_addr.city,    '—'),'raw_value',v_addr.city,    'key','addr.city',    'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','District',      'value',COALESCE(v_addr.district,'—'),'raw_value',v_addr.district,'key','addr.district','editable',true,'input_type','text','required',false),
      jsonb_build_object('label','State',         'value',COALESCE(v_addr.state,   '—'),'raw_value',v_addr.state,   'key','addr.state',   'editable',true,'input_type','text','required',false),
      jsonb_build_object('label','PIN',           'value',COALESCE(v_addr.pin,     '—'),'raw_value',v_addr.pin,     'key','addr.pin',     'editable',true,'input_type','text','required',true),
      jsonb_build_object('label','Country',       'value',COALESCE(v_addr.country, '—'),'raw_value',v_addr.country, 'key','addr.country', 'editable',true,'input_type','select','required',true)
    )
  );

  -- ── Section 8: Emergency Contact ──────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Emergency Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label','Name',         'value',COALESCE(v_ec.name,                             '—'),'raw_value',v_ec.name,         'key','ec.name',         'editable',true,'input_type','text', 'required',true),
      jsonb_build_object('label','Relationship', 'value',COALESCE(v_ec_relationship_lbl,v_ec.relationship,'—'),'raw_value',v_ec.relationship,'key','ec.relationship', 'editable',true,'input_type','picklist','required',true,'picklist_id','EMERGENCY_CONTACT_RELATIONSHIP'),
      jsonb_build_object('label','Phone',        'value',COALESCE(v_ec.phone,                            '—'),'raw_value',v_ec.phone,        'key','ec.phone',        'editable',true,'input_type','text', 'required',true),
      jsonb_build_object('label','Alt Phone',    'value',COALESCE(v_ec.alt_phone,                        '—'),'raw_value',v_ec.alt_phone,    'key','ec.alt_phone',    'editable',true,'input_type','text', 'required',false),
      jsonb_build_object('label','Email',        'value',COALESCE(v_ec.email,                            '—'),'raw_value',v_ec.email,        'key','ec.email',        'editable',true,'input_type','email','required',false)
    )
  );

  -- ── Section 9: Bank Accounts (read-only) ─────────────────────────────────
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
        jsonb_build_object('label','Effective From', 'value',COALESCE(to_char(v_bank_rec.effective_from,'DD Mon YYYY'),'—'),'raw_value',v_bank_rec.effective_from::text,'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  -- Placeholder when no bank accounts were submitted
  IF v_bank_idx = 0 THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Bank Account',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Bank Name',      'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Number', 'value','—','raw_value',NULL::text,'editable',false,'input_type','readonly','required',false)
      )
    );
  END IF;

  -- ── Section 10: Dependents (read-only) ───────────────────────────────────
  FOR v_dep_rec IN
    SELECT * FROM employee_dependents
    WHERE  employee_id = p_employee_id
      AND  is_active   = true
      AND  effective_to = '9999-12-31'::date
    ORDER  BY effective_from, created_at
  LOOP
    v_dep_idx  := v_dep_idx + 1;
    -- Resolve relationship label from picklist
    SELECT full_name INTO v_dep_rel_lbl
    FROM   picklist_values
    WHERE  picklistId = 'DEPENDENT_RELATIONSHIP_TYPE'
      AND  value      = v_dep_rec.relationship_type
    LIMIT  1;

    v_dep_label := 'Dependent ' || v_dep_idx
                || ' — ' || COALESCE(v_dep_rec.dependent_name, '');

    v_result := v_result || jsonb_build_object(
      'section', v_dep_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',             'value',COALESCE(v_dep_rec.dependent_name,                                  '—'),'raw_value',v_dep_rec.dependent_name,           'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Relationship',     'value',COALESCE(v_dep_rel_lbl, v_dep_rec.relationship_type,               '—'),'raw_value',v_dep_rec.relationship_type,         'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Date of Birth',    'value',COALESCE(to_char(v_dep_rec.date_of_birth,'DD Mon YYYY'),           '—'),'raw_value',v_dep_rec.date_of_birth::text,       'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Gender',           'value',COALESCE(v_dep_rec.gender,                                        '—'),'raw_value',v_dep_rec.gender,                    'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Insurance',        'value',CASE WHEN v_dep_rec.insurance_eligible THEN 'Yes' ELSE 'No' END,       'raw_value',v_dep_rec.insurance_eligible::text,   'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Effective From',   'value',COALESCE(to_char(v_dep_rec.effective_from,'DD Mon YYYY'),         '—'),'raw_value',v_dep_rec.effective_from::text,      'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Dependent Code',   'value',COALESCE(v_dep_rec.dependent_code,                                '—'),'raw_value',v_dep_rec.dependent_code,            'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  -- Placeholder when no dependents were submitted (optional section)
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
  'Section order: Personal Info, Contact, Business Email, Employment, '
  'Identity Document(s), Passport, Address, Emergency Contact, '
  'Bank Account(s), Dependent(s). '
  'Mig 295: added Section 10 — Dependent(s), read-only.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 295
-- =============================================================================
