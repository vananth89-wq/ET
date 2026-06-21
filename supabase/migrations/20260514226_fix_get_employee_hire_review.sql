-- =============================================================================
-- Migration 226: Fix get_employee_hire_review — satellite-table schema
--
-- PROBLEM
-- ───────
-- Migration 218 wrote get_employee_hire_review using employees%ROWTYPE and
-- accessed v_emp.nationality, v_emp.marital_status etc.  The live DB does NOT
-- store those fields on the employees table — they live in satellite tables:
--
--   employees        → employee_id, name, business_email, designation,
--                       dept_id, manager_id, hire_date, end_date,
--                       work_country, work_location, base_currency_id,
--                       status, locked
--   employee_personal  → nationality, marital_status, gender, dob, photo_url
--   employee_contact   → country_code, mobile, personal_email
--   employee_employment→ probation_end_date
--   passports          → country, passport_number, issue_date, expiry_date
--   employee_addresses → line1..country
--   emergency_contacts → name, relationship, phone, alt_phone, email
--
-- This caused runtime error:  record "v_emp" has no field "nationality"
-- (PostgreSQL error 42703)
--
-- FIX
-- ───
-- Rewrite the function to query each satellite table directly instead of
-- relying on employees%ROWTYPE for fields that live elsewhere.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_hire_review(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Core employee row (only columns guaranteed on the live employees table)
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

  -- Satellite tables
  v_personal   employee_personal%ROWTYPE;
  v_contact    employee_contact%ROWTYPE;
  v_employment employee_employment%ROWTYPE;
  v_addr       employee_addresses%ROWTYPE;
  v_passport   passports%ROWTYPE;
  v_ec         emergency_contacts%ROWTYPE;

  -- Lookup labels
  v_dept     text;
  v_manager  text;
  v_currency text;

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

  -- ── Resolve lookup labels ─────────────────────────────────────────────────
  SELECT name INTO v_dept     FROM departments WHERE id = v_dept_id;
  SELECT name INTO v_manager  FROM employees   WHERE id = v_manager_id;
  SELECT code INTO v_currency FROM currencies  WHERE id = v_base_curr_id;

  -- ── Satellite rows (NOT FOUND is fine — sections skipped when null) ───────
  SELECT * INTO v_personal   FROM employee_personal   WHERE employee_id = p_employee_id;
  SELECT * INTO v_contact    FROM employee_contact    WHERE employee_id = p_employee_id;
  SELECT * INTO v_employment FROM employee_employment WHERE employee_id = p_employee_id;
  SELECT * INTO v_addr       FROM employee_addresses  WHERE employee_id = p_employee_id;
  SELECT * INTO v_passport   FROM passports           WHERE employee_id = p_employee_id;
  SELECT * INTO v_ec         FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  -- ── Section 1: Personal Info ──────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Employee ID',    'value', COALESCE(v_emp_id,                   '—')),
      jsonb_build_object('label', 'Full Name',      'value', COALESCE(v_name,                     '—')),
      jsonb_build_object('label', 'Nationality',    'value', COALESCE(v_personal.nationality,     '—')),
      jsonb_build_object('label', 'Marital Status', 'value', COALESCE(v_personal.marital_status,  '—')),
      jsonb_build_object('label', 'Gender',         'value', COALESCE(v_personal.gender,          '—')),
      jsonb_build_object('label', 'Date of Birth',  'value', COALESCE(v_personal.dob::text,       '—')),
      jsonb_build_object('label', 'Status',         'value', COALESCE(v_status,                   '—'))
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
      jsonb_build_object('label', 'Designation',   'value', COALESCE(v_designation,                    '—')),
      jsonb_build_object('label', 'Department',    'value', COALESCE(v_dept,                            '—')),
      jsonb_build_object('label', 'Manager',       'value', COALESCE(v_manager,                         '—')),
      jsonb_build_object('label', 'Hire Date',     'value', COALESCE(v_hire_date::text,                 '—')),
      jsonb_build_object('label', 'Probation End', 'value', COALESCE(v_employment.probation_end_date::text, '—')),
      jsonb_build_object('label', 'Work Country',  'value', COALESCE(v_work_country,                    '—')),
      jsonb_build_object('label', 'Work Location', 'value', COALESCE(v_work_location,                   '—')),
      jsonb_build_object('label', 'Base Currency', 'value', COALESCE(v_currency,                        '—'))
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
        jsonb_build_object('label', 'Country',         'value', COALESCE(v_passport.country,         '—')),
        jsonb_build_object('label', 'Passport Number', 'value', COALESCE(v_passport.passport_number, '—')),
        jsonb_build_object('label', 'Issue Date',      'value', COALESCE(v_passport.issue_date::text,'—')),
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

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all employee sections as structured JSONB [{section, fields:[{label,value}]}] for WorkflowReview rendering. '
  'Queries satellite tables (employee_personal, employee_contact, employee_employment, passports, '
  'employee_addresses, emergency_contacts) rather than employees%ROWTYPE, matching the live DB schema.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 226
-- =============================================================================
