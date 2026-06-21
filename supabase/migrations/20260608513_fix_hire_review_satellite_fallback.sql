-- =============================================================================
-- Migration 513 — Fix get_employee_hire_review: fall back to employee_employment
--                 satellite for pending hires (mig 456 removed base-table mirror)
--
-- ROOT CAUSE
-- ──────────
-- Since mig 456, upsert_employment_info no longer mirrors employment fields
-- (designation, dept_id, hire_date, work_country, work_location, manager_id,
-- base_currency_id) to the employees base table during the hire pipeline.
-- These fields now live ONLY in the employee_employment satellite until the
-- hire is approved — wf_activate_employee does the one-time mirror on approval.
--
-- get_employee_hire_review reads those fields from employees base, so for any
-- pending hire they come back NULL → WorkflowReview shows "— select —" for
-- Designation, Department, Work Country, Work Location dropdowns.
--
-- Probation End Date was unaffected because it always read from v_employment.
--
-- FIX
-- ───
-- After the employees SELECT, immediately fetch the open-ended satellite slice.
-- Then COALESCE each employment field: prefer the base-table value (set after
-- activation) and fall back to the satellite value (set during hire pipeline).
-- Labels are resolved after the COALESCE, so they always get the right UUID.
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
  v_work_country   text;
  v_work_location  text;
  v_base_curr_id   uuid;
  v_status         text;

  v_first_name     text;
  v_middle_name    text;
  v_last_name      text;
  v_full_name      text;
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

  v_edu_rec        RECORD;
  v_edu_idx        int := 0;
  v_edu_level_lbl  text;
  v_edu_status_lbl text;

  v_result   jsonb := '[]'::jsonb;
BEGIN
  -- ── 1. Base-table read ────────────────────────────────────────────────────
  SELECT
    employee_id, name, business_email, designation,
    dept_id, manager_id, hire_date,
    work_country, work_location, base_currency_id, status::text
  INTO
    v_emp_id, v_name, v_business_email, v_designation,
    v_dept_id, v_manager_id, v_hire_date,
    v_work_country, v_work_location, v_base_curr_id, v_status
  FROM employees WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  -- ── 2. Satellite read (early — needed for COALESCE below) ─────────────────
  -- Fetch the open-ended, active employment slice.  For pending hires this
  -- row holds the canonical employment data; for active employees it is the
  -- same data already mirrored into employees base (COALESCE is a no-op).
  SELECT * INTO v_employment
  FROM   employee_employment
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  ORDER  BY effective_from DESC
  LIMIT  1;

  -- ── 3. COALESCE base ← satellite for pending hires ───────────────────────
  v_designation  := COALESCE(NULLIF(v_designation, ''),  v_employment.designation);
  v_dept_id      := COALESCE(v_dept_id,                  v_employment.dept_id);
  v_manager_id   := COALESCE(v_manager_id,               v_employment.manager_id);
  v_hire_date    := COALESCE(v_hire_date,                 v_employment.hire_date);
  v_work_country := COALESCE(NULLIF(v_work_country, ''), v_employment.work_country);
  v_work_location:= COALESCE(NULLIF(v_work_location,''), v_employment.work_location);
  v_base_curr_id := COALESCE(v_base_curr_id,             v_employment.base_currency_id);

  -- ── 4. Label resolution (now always has non-NULL UUIDs for pending hires) ─
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

  SELECT first_name, middle_name, last_name, name,
         nationality, marital_status, gender, dob
  INTO   v_first_name, v_middle_name, v_last_name, v_full_name,
         v_nationality, v_marital_raw, v_gender, v_dob
  FROM   employee_personal
  WHERE  employee_id = p_employee_id
  LIMIT  1;

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

  v_full_name := COALESCE(NULLIF(trim(v_full_name), ''), v_name);

  IF v_marital_raw IS NOT NULL THEN
    SELECT value INTO v_marital_label
    FROM   picklist_values WHERE id::text = v_marital_raw LIMIT 1;
    v_marital_label := COALESCE(v_marital_label, v_marital_raw);
  END IF;

  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id;
  -- v_employment already fetched above
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
      jsonb_build_object('label','Full Name',      'value',COALESCE(NULLIF(v_full_name,''),'—'),'raw_value',v_full_name,   'key','emp.full_name',          'editable',false,'input_type','readonly','required',false),
      jsonb_build_object('label','First Name',     'value',COALESCE(v_first_name,        '—'),'raw_value',v_first_name,      'key','personal.first_name',    'editable',true, 'input_type','text',    'required',true),
      jsonb_build_object('label','Middle Name',    'value',COALESCE(v_middle_name,       '—'),'raw_value',v_middle_name,     'key','personal.middle_name',   'editable',true, 'input_type','text',    'required',false),
      jsonb_build_object('label','Last Name',      'value',COALESCE(v_last_name,         '—'),'raw_value',v_last_name,       'key','personal.last_name',     'editable',true, 'input_type','text',    'required',true),
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

  -- ── Section 4: Passport ───────────────────────────────────────────────────
  IF v_passport_required THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Passport',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',      'value',COALESCE(v_passport_country_lbl,      '—'),'raw_value',v_passport.country,           'key','passport.country',       'editable',true, 'input_type','select','required',true),
        jsonb_build_object('label','Passport No.', 'value',COALESCE(v_passport.passport_number,  '—'),'raw_value',v_passport.passport_number,   'key','passport.number',        'editable',true, 'input_type','text',  'required',true),
        jsonb_build_object('label','Issue Date',   'value',COALESCE(v_passport.issue_date::text,  '—'),'raw_value',v_passport.issue_date::text, 'key','passport.issue_date',    'editable',true, 'input_type','date',  'required',true),
        jsonb_build_object('label','Expiry Date',  'value',COALESCE(v_passport.expiry_date::text, '—'),'raw_value',v_passport.expiry_date::text,'key','passport.expiry_date',   'editable',true, 'input_type','date',  'required',true)
      )
    );
  END IF;

  -- ── Section 5: Address ────────────────────────────────────────────────────
  IF v_addr.employee_id IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Address',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Line 1',    'value',COALESCE(v_addr.line1,    '—'),'raw_value',v_addr.line1,    'key','addr.line1',    'editable',true,'input_type','text','required',true),
        jsonb_build_object('label','Line 2',    'value',COALESCE(v_addr.line2,    '—'),'raw_value',v_addr.line2,    'key','addr.line2',    'editable',true,'input_type','text','required',false),
        jsonb_build_object('label','Landmark',  'value',COALESCE(v_addr.landmark, '—'),'raw_value',v_addr.landmark, 'key','addr.landmark', 'editable',true,'input_type','text','required',false),
        jsonb_build_object('label','City',      'value',COALESCE(v_addr.city,     '—'),'raw_value',v_addr.city,     'key','addr.city',     'editable',true,'input_type','text','required',true),
        jsonb_build_object('label','District',  'value',COALESCE(v_addr.district, '—'),'raw_value',v_addr.district, 'key','addr.district', 'editable',true,'input_type','text','required',false),
        jsonb_build_object('label','State',     'value',COALESCE(v_addr.state,    '—'),'raw_value',v_addr.state,    'key','addr.state',    'editable',true,'input_type','text','required',false),
        jsonb_build_object('label','PIN',       'value',COALESCE(v_addr.pin,      '—'),'raw_value',v_addr.pin,      'key','addr.pin',      'editable',true,'input_type','text','required',true),
        jsonb_build_object('label','Country',   'value',COALESCE(v_addr.country,  '—'),'raw_value',v_addr.country,  'key','addr.country',  'editable',true,'input_type','text','required',true)
      )
    );
  END IF;

  -- ── Section 6: Emergency Contact ─────────────────────────────────────────
  IF v_ec.employee_id IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Emergency Contact',
      'fields', jsonb_build_array(
        jsonb_build_object('label','Name',         'value',COALESCE(v_ec.name,              '—'),'raw_value',v_ec.name,             'key','ec.name',        'editable',true,'input_type','text', 'required',true),
        jsonb_build_object('label','Relationship', 'value',COALESCE(v_ec_relationship_lbl,  '—'),'raw_value',v_ec.relationship,     'key','ec.relationship','editable',true,'input_type','text', 'required',true),
        jsonb_build_object('label','Phone',        'value',COALESCE(v_ec.phone,             '—'),'raw_value',v_ec.phone,            'key','ec.phone',       'editable',true,'input_type','text', 'required',true),
        jsonb_build_object('label','Alt. Phone',   'value',COALESCE(v_ec.alt_phone,         '—'),'raw_value',v_ec.alt_phone,        'key','ec.alt_phone',   'editable',true,'input_type','text', 'required',false),
        jsonb_build_object('label','Email',        'value',COALESCE(v_ec.email,             '—'),'raw_value',v_ec.email,            'key','ec.email',       'editable',true,'input_type','email','required',false)
      )
    );
  END IF;

  -- ── Section 7+: Identity Documents ───────────────────────────────────────
  FOR v_id_rec IN
    SELECT * FROM identity_records WHERE employee_id = p_employee_id ORDER BY created_at
  LOOP
    v_id_idx := v_id_idx + 1;
    v_id_key_prefix := 'id.' || v_id_rec.id::text;
    SELECT value INTO v_id_country_lbl FROM picklist_values WHERE id::text = v_id_rec.country    LIMIT 1;
    SELECT value INTO v_id_type_lbl    FROM picklist_values WHERE id::text = v_id_rec.id_type    LIMIT 1;
    SELECT value INTO v_id_rectype_lbl FROM picklist_values WHERE id::text = v_id_rec.record_type LIMIT 1;
    v_id_country_lbl := COALESCE(v_id_country_lbl, v_id_rec.country);
    v_id_type_lbl    := COALESCE(v_id_type_lbl,    v_id_rec.id_type);
    v_id_rectype_lbl := COALESCE(v_id_rectype_lbl, v_id_rec.record_type);
    v_result := v_result || jsonb_build_object(
      'section', 'Identity Document ' || v_id_idx,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Country',     'value',COALESCE(v_id_country_lbl,     '—'),'raw_value',v_id_rec.country,      'key',v_id_key_prefix||'.country',     'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','ID Type',     'value',COALESCE(v_id_type_lbl,        '—'),'raw_value',v_id_rec.id_type,      'key',v_id_key_prefix||'.id_type',     'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Record Type', 'value',COALESCE(v_id_rectype_lbl,     '—'),'raw_value',v_id_rec.record_type,  'key',v_id_key_prefix||'.record_type', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','ID Number',   'value',COALESCE(v_id_rec.id_number,   '—'),'raw_value',v_id_rec.id_number,    'key',v_id_key_prefix||'.id_number',   'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Expiry',      'value',COALESCE(v_id_rec.expiry::text,'—'),'raw_value',v_id_rec.expiry::text, 'key',v_id_key_prefix||'.expiry',      'editable',false,'input_type','readonly','required',false)
      )
    );
  END LOOP;

  -- ── Bank Account sections ─────────────────────────────────────────────────
  FOR v_bank_rec IN
    SELECT i.*
    FROM   employee_bank_account_item i
    JOIN   employee_bank_account_set  s ON s.id = i.set_id
    WHERE  s.employee_id  = p_employee_id
      AND  s.is_active    = true
      AND  s.effective_to = '9999-12-31'::date
    ORDER  BY i.is_primary DESC, i.bank_name
  LOOP
    v_bank_idx   := v_bank_idx + 1;
    v_bank_label := CASE WHEN v_bank_rec.is_primary THEN 'Bank Account (Primary)' ELSE 'Bank Account ' || v_bank_idx END;
    v_result := v_result || jsonb_build_object(
      'section', v_bank_label,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Bank Name',      'value',COALESCE(v_bank_rec.bank_name,           '—'),'raw_value',v_bank_rec.bank_name,           'key','bank.'||v_bank_rec.id::text||'.bank_name',           'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Number', 'value',COALESCE(v_bank_rec.account_number,      '—'),'raw_value',v_bank_rec.account_number,      'key','bank.'||v_bank_rec.id::text||'.account_number',      'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Account Holder', 'value',COALESCE(v_bank_rec.account_holder_name, '—'),'raw_value',v_bank_rec.account_holder_name, 'key','bank.'||v_bank_rec.id::text||'.account_holder_name', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Currency',       'value',COALESCE(v_bank_rec.currency_code,       '—'),'raw_value',v_bank_rec.currency_code,       'key','bank.'||v_bank_rec.id::text||'.currency_code',       'editable',false,'input_type','readonly','required',false)
      ),
      'attachments', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'file_name', a.file_name, 'file_type', a.file_type,
          'file_size', a.file_size, 'storage_path', a.storage_path
        ) ORDER BY a.uploaded_at), '[]'::jsonb)
        FROM employee_bank_attachments a
        WHERE a.bank_account_item_id = v_bank_rec.id AND a.is_active = true
      )
    );
  END LOOP;

  -- ── Dependent sections ────────────────────────────────────────────────────
  FOR v_dep_rec IN
    SELECT i.*
    FROM   employee_dependent_item i
    JOIN   employee_dependent_set  s ON s.id = i.set_id
    WHERE  s.employee_id  = p_employee_id
      AND  s.is_active    = true
      AND  s.effective_to = '9999-12-31'::date
    ORDER  BY i.created_at
  LOOP
    v_dep_idx   := v_dep_idx + 1;
    v_dep_label := 'Dependent ' || v_dep_idx;
    v_dep_rel_lbl := NULL;
    IF v_dep_rec.relationship_type IS NOT NULL THEN
      SELECT pv.value INTO v_dep_rel_lbl
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
        jsonb_build_object('label','Name',         'value',COALESCE(v_dep_rec.dependent_name,      '—'),'raw_value',v_dep_rec.dependent_name,    'key','dep.'||v_dep_rec.id::text||'.dependent_name',    'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Relationship', 'value',COALESCE(v_dep_rel_lbl,                 '—'),'raw_value',v_dep_rec.relationship_type, 'key','dep.'||v_dep_rec.id::text||'.relationship_type', 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Date of Birth','value',COALESCE(v_dep_rec.date_of_birth::text, '—'),'raw_value',v_dep_rec.date_of_birth::text,'key','dep.'||v_dep_rec.id::text||'.dob',               'editable',false,'input_type','readonly','required',false)
      ),
      'attachments', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'file_name', a.file_name, 'original_file_name', a.original_file_name,
          'mime_type', a.mime_type, 'file_size', a.file_size, 'file_path', a.file_path
        ) ORDER BY a.uploaded_at), '[]'::jsonb)
        FROM employee_dependent_attachments a
        WHERE a.dependent_code = v_dep_rec.dependent_code
          AND a.employee_id    = p_employee_id
          AND a.is_active      = true
      )
    );
  END LOOP;

  -- ── Education sections ────────────────────────────────────────────────────
  FOR v_edu_rec IN
    SELECT * FROM employee_education
    WHERE  employee_id = p_employee_id AND is_active = true
    ORDER  BY created_at
  LOOP
    v_edu_idx := v_edu_idx + 1;
    v_edu_level_lbl := NULL; v_edu_status_lbl := NULL;
    SELECT pv.value INTO v_edu_level_lbl  FROM picklist_values pv JOIN picklists pl ON pl.id = pv.picklist_id WHERE pl.picklist_id = 'EDUCATION_LEVEL'    AND pv.ref_id = v_edu_rec.education_level   LIMIT 1;
    SELECT pv.value INTO v_edu_status_lbl FROM picklist_values pv JOIN picklists pl ON pl.id = pv.picklist_id WHERE pl.picklist_id = 'COMPLETION_STATUS'   AND pv.ref_id = v_edu_rec.completion_status LIMIT 1;
    v_edu_level_lbl  := COALESCE(v_edu_level_lbl,  v_edu_rec.education_level);
    v_edu_status_lbl := COALESCE(v_edu_status_lbl, v_edu_rec.completion_status);
    v_result := v_result || jsonb_build_object(
      'section', 'Education ' || v_edu_idx,
      'fields', jsonb_build_array(
        jsonb_build_object('label','Education Level',      'value',COALESCE(v_edu_level_lbl,                    '—'),'raw_value',v_edu_rec.education_level,     'key','edu.'||v_edu_rec.id::text||'.education_level',              'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Degree',               'value',COALESCE(v_edu_rec.degree,                   '—'),'raw_value',v_edu_rec.degree,              'key','edu.'||v_edu_rec.id::text||'.degree',                       'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Institution',          'value',COALESCE(v_edu_rec.institution,              '—'),'raw_value',v_edu_rec.institution,         'key','edu.'||v_edu_rec.id::text||'.institution',                  'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Start Date',           'value',COALESCE(v_edu_rec.start_date::text,         '—'),'raw_value',v_edu_rec.start_date::text,    'key','edu.'||v_edu_rec.id::text||'.start_date',                   'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','End Date',             'value',COALESCE(v_edu_rec.end_date::text,           '—'),'raw_value',v_edu_rec.end_date::text,      'key','edu.'||v_edu_rec.id::text||'.end_date',                     'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Completion Status',    'value',COALESCE(v_edu_status_lbl,                   '—'),'raw_value',v_edu_rec.completion_status,   'key','edu.'||v_edu_rec.id::text||'.completion_status',            'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Grade / GPA',          'value',COALESCE(v_edu_rec.grade_or_gpa,             '—'),'raw_value',v_edu_rec.grade_or_gpa,        'key','edu.'||v_edu_rec.id::text||'.grade_or_gpa',                 'editable',false,'input_type','readonly','required',false),
        jsonb_build_object('label','Highest Qualification','value',CASE WHEN v_edu_rec.is_highest_qualification THEN 'Yes' ELSE 'No' END,'raw_value',v_edu_rec.is_highest_qualification::text,'key','edu.'||v_edu_rec.id::text||'.is_highest_qualification','editable',false,'input_type','readonly','required',false)
      ),
      'attachments', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'file_name', a.file_name, 'original_file_name', a.original_file_name,
          'mime_type', a.mime_type, 'file_size', a.file_size, 'file_path', a.file_path
        ) ORDER BY a.uploaded_at), '[]'::jsonb)
        FROM employee_education_attachments a WHERE a.education_id = v_edu_rec.id
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

REVOKE ALL     ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Mig 513: fetch employee_employment satellite early and COALESCE employment '
  'fields (designation, dept_id, hire_date, work_country, work_location, '
  'manager_id, base_currency_id) so pending hires show correct values. '
  'Base-table values (post-activation) take priority; satellite is the fallback.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 513: get_employee_hire_review — employment fields now read from satellite for pending hires.';
END;
$$;
