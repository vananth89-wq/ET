-- =============================================================================
-- Migration 457 — validate_hire_fields: read employment from satellite
--
-- PROBLEM
-- ───────
-- validate_hire_fields (mig 438) checks employment completeness by reading
-- from the employees base table:
--
--   IF v_emp.designation IS NULL OR v_emp.hire_date IS NULL ...
--
-- With mig 456, upsert_employment_info no longer mirrors to employees for
-- Draft/Incomplete/Pending records. So employees.designation etc. will be NULL
-- for all hire-pipeline records, and validate_hire_fields will always raise
-- "Employment incomplete" even when the user has filled in all fields.
--
-- FIX
-- ───
-- Replace the base-table employment check with a satellite read:
--
--   IF NOT EXISTS (
--     SELECT 1 FROM employee_employment
--     WHERE employee_id = p_employee_id
--       AND effective_to = '9999-12-31' AND is_active = true
--       AND designation IS NOT NULL
--       AND hire_date IS NOT NULL
--       ...
--   ) THEN v_missing := array_append(v_missing, 'Employment');
--
-- All other checks (Personal, Contact, Email, Address, Emergency, Bank) are
-- unchanged — they already read from their respective satellite tables.
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

  -- ── Email: business_email on employees base table ──────────────────────────
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    v_missing := array_append(v_missing, 'Email');
  END IF;

  -- ── Employment: read from satellite (mig 457) ─────────────────────────────
  -- Previously read from employees base (designation, hire_date, etc.).
  -- With mig 456, those fields are no longer mirrored during hire pipeline,
  -- so we read from the open-ended employment satellite slice instead.
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
  'Validates all 7 required hire sections for the given employee record. '
  'Raises check_violation listing every missing section. '
  'Called by both submit_hire and wf_resubmit. '
  'Mig 260: initial. Mig 431: added Bank, tightened Personal/Employment/Emergency. '
  'Mig 438: tightened Personal (marital_status), Employment (probation_end_date). '
  'Mig 457: Employment check reads from employee_employment satellite instead of '
  'employees base (required after mig 456 removed mirror for Draft/Pending records).';

DO $$
BEGIN
  RAISE NOTICE 'Migration 457: validate_hire_fields updated — employment check now reads from satellite.';
END;
$$;
