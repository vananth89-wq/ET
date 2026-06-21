-- =============================================================================
-- Migration 479 — validate_hire_fields: definitive clean version
--
-- ROOT CAUSE ANALYSIS
-- ───────────────────
-- validate_hire_fields has been redefined four times:
--
--   Mig 260 (validate_hire_fields_shared)
--     Employment check reads from employees base:
--       v_emp.designation, hire_date, work_country, work_location
--     ✓ All four fields exist on employees at this point.
--
--   Mig 431 (tighten_validate_hire_fields)
--     Adds dept_id to the employment check:
--       v_emp.dept_id
--     ✓ dept_id exists on employees.
--
--   Mig 441 (tighten_validate_hire_fields_probation_marital)   ← BUG INTRODUCED
--     Adds probation_end_date to the employment check:
--       v_emp.probation_end_date IS NULL
--     ✗ probation_end_date was NEVER on employees post mig 020
--       (it was dropped from employees in mig 020 and lives exclusively
--        in employee_employment satellite since mig 351).
--     ✗ This causes runtime error at submit time:
--       "record v_emp has no field probation_end_date" (ERRCODE 42703)
--
--   Mig 457 (validate_hire_fields_read_satellite)
--     Correct fix: reads all employment fields from employee_employment satellite.
--     ✓ Deployed to file but NOT yet pushed to remote DB.
--
-- THIS MIGRATION (479)
-- ────────────────────
-- Supersedes mig 457 with the same correct logic, ensuring it reaches
-- the remote DB regardless of whether mig 457 was applied.
-- All employment validation now reads from employee_employment satellite.
-- Personal, Contact, Email, Address, Emergency, Bank checks are unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION validate_hire_fields(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp     employees%ROWTYPE;
  v_missing text[] := '{}';
BEGIN
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'validate_hire_fields: employee % not found.', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- ── Personal: first_name + nationality + gender + dob + marital_status ─────
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id    = p_employee_id
      AND  first_name     IS NOT NULL AND first_name != ''
      AND  nationality    IS NOT NULL
      AND  gender         IS NOT NULL
      AND  dob            IS NOT NULL
      AND  marital_status IS NOT NULL
  ) THEN v_missing := array_append(v_missing, 'Personal'); END IF;

  -- ── Contact: mobile ────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employee_contact
    WHERE  employee_id = p_employee_id
      AND  mobile IS NOT NULL AND mobile != ''
  ) THEN v_missing := array_append(v_missing, 'Contact'); END IF;

  -- ── Email: business_email (lives on employees base) ───────────────────────
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    v_missing := array_append(v_missing, 'Email');
  END IF;

  -- ── Employment: read from employee_employment satellite ────────────────────
  -- probation_end_date was NEVER on employees (dropped in mig 020).
  -- All employment fields live in employee_employment since mig 351.
  -- Mig 441 incorrectly read v_emp.probation_end_date → runtime 42703 error.
  IF NOT EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id        = p_employee_id
      AND  effective_to       = '9999-12-31'::date
      AND  is_active          = true
      AND  designation        IS NOT NULL
      AND  hire_date          IS NOT NULL
      AND  work_country       IS NOT NULL
      AND  work_location      IS NOT NULL
      AND  dept_id            IS NOT NULL
      AND  probation_end_date IS NOT NULL
  ) THEN v_missing := array_append(v_missing, 'Employment'); END IF;

  -- ── Address: line1 + city + pin + country ─────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employee_addresses
    WHERE  employee_id = p_employee_id
      AND  line1   IS NOT NULL AND line1   != ''
      AND  city    IS NOT NULL AND city    != ''
      AND  pin     IS NOT NULL AND pin     != ''
      AND  country IS NOT NULL AND country != ''
  ) THEN v_missing := array_append(v_missing, 'Address'); END IF;

  -- ── Emergency Contact: ≥1 row with name + phone ───────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM emergency_contacts
    WHERE  employee_id = p_employee_id
      AND  name  IS NOT NULL AND name  != ''
      AND  phone IS NOT NULL AND phone != ''
  ) THEN v_missing := array_append(v_missing, 'Emergency Contact'); END IF;

  -- ── Bank: ≥1 active set with ≥1 item ──────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1
    FROM   employee_bank_account_set s
    JOIN   employee_bank_account_item i ON i.set_id = s.id
    WHERE  s.employee_id = p_employee_id
      AND  s.is_active   = true
  ) THEN v_missing := array_append(v_missing, 'Bank Account'); END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'Cannot submit: the following required sections are incomplete: %. '
      'Please complete all required sections before submitting.',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

COMMENT ON FUNCTION validate_hire_fields(uuid) IS
  'Validates all 7 required hire sections. Raises check_violation listing every '
  'missing section. Called by submit_hire and wf_resubmit. '
  'Mig 260: initial. '
  'Mig 431: added Bank, tightened Personal (first_name), Employment (dept_id), Emergency (phone). '
  'Mig 441: added marital_status + probation_end_date — BUG: probation_end_date read from '
  '         employees base which never had it (dropped in mig 020). '
  'Mig 457/479: Employment check now reads from employee_employment satellite. '
  '             Fixes runtime 42703 error on submit.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 479: validate_hire_fields — employment check reads from satellite. '
               'Fixes "record v_emp has no field probation_end_date" (42703) on submit_hire.';
END;
$$;
