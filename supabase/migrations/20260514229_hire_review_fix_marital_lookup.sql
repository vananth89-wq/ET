-- =============================================================================
-- Migration 229: get_employee_hire_review — fix marital_status picklist lookup
--
-- PROBLEM
-- ───────
-- In migration 228, the marital_status picklist resolution uses:
--
--   SELECT value INTO v_marital_label
--   FROM   picklist_values WHERE id::text = v_personal.marital_status LIMIT 1;
--
-- This always returns NULL despite the data being present and the same JOIN
-- working correctly in plain SQL.  The root cause is a PL/pgSQL plan-caching
-- quirk: when a composite-type field (v_personal.marital_status) is used
-- directly in a parameterised SQL WHERE clause, the substituted value can be
-- lost.  The standard fix is to copy the field into a plain scalar variable
-- before using it in the SQL statement.
--
-- The same defensive pattern is applied to all other picklist fields that are
-- read from rowtype composites (identity_records loop) for consistency.
--
-- FIX
-- ───
-- Declare v_marital_status_raw text and assign v_personal.marital_status to it
-- before the picklist lookup, then use v_marital_status_raw in the WHERE clause.
-- Identical defensive copies are added in the identity_records loop.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_hire_review(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Core employee columns (guaranteed on the live employees table)
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

  -- Satellite rows
  v_personal   employee_personal%ROWTYPE;
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

  -- Plain scalar copies of rowtype fields used in SQL WHERE clauses.
  -- Required: PL/pgSQL plan caching does not reliably substitute composite
  -- record fields; copying to a plain variable forces correct substitution.
  v_marital_status_raw  text;

  -- Identity records loop
  v_id_rec          identity_records%ROWTYPE;
  v_id_idx          int := 0;
  v_id_country_raw  text;
  v_id_type_raw     text;
  v_id_rectype_raw  text;
  v_id_country_lbl  text;
  v_id_type_lbl     text;
  v_id_rectype_lbl  text;

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
  -- These come from plain scalar variables so no special handling needed.
  SELECT value INTO v_designation_label
  FROM   picklist_values WHERE id::text = v_designation LIMIT 1;
  v_designation_label := COALESCE(v_designation_label, v_designation);

  SELECT value INTO v_work_country_label
  FROM   picklist_values WHERE id::text = v_work_country LIMIT 1;
  v_work_country_label := COALESCE(v_work_country_label, v_work_country);

  SELECT value INTO v_work_location_label
  FROM   picklist_values WHERE id::text = v_work_location LIMIT 1;
  v_work_location_label := COALESCE(v_work_location_label, v_work_location);

  -- ── Satellite rows ────────────────────────────────────────────────────────
  SELECT * INTO v_personal   FROM employee_personal   WHERE employee_id = p_employee_id;
  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id;
  SELECT * INTO v_employment FROM employee_employment WHERE employee_id = p_employee_id;
  SELECT * INTO v_addr       FROM employee_addresses  WHERE employee_id = p_employee_id;
  SELECT * INTO v_passport   FROM passports           WHERE employee_id = p_employee_id;
  SELECT * INTO v_ec         FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  -- ── Resolve marital_status UUID ───────────────────────────────────────────
  -- Copy composite field to plain scalar BEFORE using in SQL WHERE clause.
  IF v_personal IS NOT NULL THEN
    v_marital_status_raw := v_personal.marital_status;
    SELECT value INTO v_marital_label
    FROM   picklist_values WHERE id::text = v_marital_status_raw LIMIT 1;
    v_marital_label := COALESCE(v_marital_label, v_marital_status_raw);
  END IF;

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Employee ID',    'value', COALESCE(v_emp_id,               '—')),
      jsonb_build_object('label', 'Full Name',      'value', COALESCE(v_name,                 '—')),
      jsonb_build_object('label', 'Nationality',    'value', COALESCE(v_personal.nationality, '—')),
      jsonb_build_object('label', 'Marital Status', 'value', COALESCE(v_marital_label,        '—')),
      jsonb_build_object('label', 'Gender',         'value', COALESCE(v_personal.gender,      '—')),
      jsonb_build_object('label', 'Date of Birth',  'value', COALESCE(v_personal.dob::text,   '—')),
      jsonb_build_object('label', 'Status',         'value', COALESCE(v_status,               '—'))
    )
  );

  -- ── Section 2: Contact ────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Business Email',
        'value', COALESCE(v_business_email, '—')),
      jsonb_build_object('label', 'Personal Email',
        'value', COALESCE(v_contact.personal_email, '—')),
      jsonb_build_object('label', 'Mobile',
        'value', COALESCE(
          NULLIF(CONCAT_WS(' ', v_contact.country_code, v_contact.mobile), ''),
          '—'
        ))
    )
  );

  -- ── Section 3: Employment ─────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Designation',   'value', COALESCE(v_designation_label,                   '—')),
      jsonb_build_object('label', 'Department',    'value', COALESCE(v_dept,                                 '—')),
      jsonb_build_object('label', 'Manager',       'value', COALESCE(v_manager,                              '—')),
      jsonb_build_object('label', 'Hire Date',     'value', COALESCE(v_hire_date::text,                      '—')),
      jsonb_build_object('label', 'Probation End', 'value', COALESCE(v_employment.probation_end_date::text,  '—')),
      jsonb_build_object('label', 'Work Country',  'value', COALESCE(v_work_country_label,                   '—')),
      jsonb_build_object('label', 'Work Location', 'value', COALESCE(v_work_location_label,                  '—')),
      jsonb_build_object('label', 'Base Currency', 'value', COALESCE(v_currency,                             '—'))
    )
  );

  -- ── Section 4: Address ────────────────────────────────────────────────────
  IF v_addr IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Address',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Line 1',   'value', COALESCE(v_addr.line1,    '—')),
        jsonb_build_object('label', 'Line 2',   'value', COALESCE(v_addr.line2,    '—')),
        jsonb_build_object('label', 'Landmark', 'value', COALESCE(v_addr.landmark, '—')),
        jsonb_build_object('label', 'City',     'value', COALESCE(v_addr.city,     '—')),
        jsonb_build_object('label', 'District', 'value', COALESCE(v_addr.district, '—')),
        jsonb_build_object('label', 'State',    'value', COALESCE(v_addr.state,    '—')),
        jsonb_build_object('label', 'PIN',      'value', COALESCE(v_addr.pin,      '—')),
        jsonb_build_object('label', 'Country',  'value', COALESCE(v_addr.country,  '—'))
      )
    );
  END IF;

  -- ── Section 5: Passport ───────────────────────────────────────────────────
  IF v_passport IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Passport',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Country',         'value', COALESCE(v_passport.country,          '—')),
        jsonb_build_object('label', 'Passport Number', 'value', COALESCE(v_passport.passport_number,  '—')),
        jsonb_build_object('label', 'Issue Date',      'value', COALESCE(v_passport.issue_date::text, '—')),
        jsonb_build_object('label', 'Expiry Date',     'value', COALESCE(v_passport.expiry_date::text,'—'))
      )
    );
  END IF;

  -- ── Section 6: Emergency Contact ──────────────────────────────────────────
  IF v_ec IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Emergency Contact',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Name',         'value', COALESCE(v_ec.name,         '—')),
        jsonb_build_object('label', 'Relationship', 'value', COALESCE(v_ec.relationship, '—')),
        jsonb_build_object('label', 'Phone',        'value', COALESCE(v_ec.phone,        '—')),
        jsonb_build_object('label', 'Alt Phone',    'value', COALESCE(v_ec.alt_phone,    '—')),
        jsonb_build_object('label', 'Email',        'value', COALESCE(v_ec.email,        '—'))
      )
    );
  END IF;

  -- ── Section 7: Identity Documents (one sub-section per record) ────────────
  FOR v_id_rec IN
    SELECT * FROM identity_records
    WHERE  employee_id = p_employee_id
    ORDER  BY created_at
  LOOP
    v_id_idx := v_id_idx + 1;

    -- Copy composite fields to plain scalars before using in SQL WHERE clauses.
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
        jsonb_build_object('label', 'Country',     'value', COALESCE(v_id_country_lbl,  '—')),
        jsonb_build_object('label', 'ID Type',     'value', COALESCE(v_id_type_lbl,     '—')),
        jsonb_build_object('label', 'Record Type', 'value', COALESCE(v_id_rectype_lbl,  '—')),
        jsonb_build_object('label', 'ID Number',   'value', COALESCE(v_id_rec.id_number,'—')),
        jsonb_build_object('label', 'Expiry',      'value', COALESCE(v_id_rec.expiry::text, '—'))
      )
    );
  END LOOP;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all employee sections as structured JSONB [{section, fields:[{label,value}]}] for WorkflowReview rendering. '
  'Sections: Personal Info, Contact, Employment, Address (if any), Passport (if any), '
  'Emergency Contact (if any), Identity Document N (one per identity_records row). '
  'All picklist UUID fields are resolved to display labels via picklist_values. '
  'Uses explicit scalar copies of rowtype fields before SQL WHERE clauses to work around PL/pgSQL plan-caching quirk.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 229
-- =============================================================================
