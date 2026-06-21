-- =============================================================================
-- Migration 438 — Further tighten validate_hire_fields()
-- =============================================================================
--
-- WHAT
-- ────
-- Adds two checks that the frontend enforces but the backend did not:
--
--   Employment: probation_end_date IS NOT NULL
--     employees.probation_end_date is set via the Employment step of the hire
--     wizard. The frontend requires it before marking the Employment section
--     complete, but the backend gate (mig 431) only checked designation,
--     hire_date, work_country, work_location, and dept_id.
--
--   Personal: marital_status IS NOT NULL
--     employee_personal.marital_status is required in the Personal step.
--     Mig 431 checked nationality, gender, dob, and first_name but omitted
--     marital_status.
--
-- WHY
-- ───
-- The backend gate should be authoritative. Any field the frontend requires
-- before submission should also be enforced server-side so direct RPC callers
-- (API consumers, future integrations) cannot submit an incomplete hire.
--
-- SAFETY
-- ──────
-- Additive validation only — no data is modified. Active employees are
-- unaffected (validate_hire_fields is only called by submit_hire and
-- wf_resubmit, both guarded to Draft/Incomplete/Pending status).
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

  -- ── Personal: first_name + nationality + gender + dob + marital_status ───
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id   = p_employee_id
      AND  first_name    IS NOT NULL AND first_name != ''
      AND  nationality   IS NOT NULL
      AND  gender        IS NOT NULL
      AND  dob           IS NOT NULL
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

  -- ── Employment: designation + hire_date + work_country + work_location
  --               + dept_id + probation_end_date ─────────────────────────────
  IF v_emp.designation       IS NULL
     OR v_emp.hire_date       IS NULL
     OR v_emp.work_country    IS NULL
     OR v_emp.work_location   IS NULL
     OR v_emp.dept_id         IS NULL
     OR v_emp.probation_end_date IS NULL
  THEN
    v_missing := array_append(v_missing, 'Employment');
  END IF;

  -- ── Address: line1 + city + pin + country ─────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employee_addresses
    WHERE  employee_id = p_employee_id
      AND  line1   IS NOT NULL AND line1   != ''
      AND  city    IS NOT NULL AND city    != ''
      AND  pin     IS NOT NULL AND pin     != ''
      AND  country IS NOT NULL AND country != ''
  ) THEN v_missing := array_append(v_missing, 'Address'); END IF;

  -- ── Emergency Contact: ≥1 row with name + phone ────────────────────────────
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
  'Validates all 7 required hire sections (Personal, Contact, Email, Employment, '
  'Address, Emergency Contact, Bank Account) for the given employee record. '
  'Raises check_violation listing every missing section. '
  'Called by both submit_hire and wf_resubmit. '
  'Mig 260: initial 6-section version. '
  'Mig 431: added Bank check; tightened Personal (first_name), Employment (dept_id), Emergency (phone). '
  'Mig 438: tightened Personal (marital_status), Employment (probation_end_date). '
  'Backend gate now matches frontend requirements exactly.';

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public' AND routine_name = 'validate_hire_fields'
  ) THEN
    RAISE EXCEPTION 'ABORT: validate_hire_fields missing after migration 438.';
  END IF;
  RAISE NOTICE 'Migration 438 verified: validate_hire_fields updated with probation_end_date and marital_status checks.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 438
-- =============================================================================
