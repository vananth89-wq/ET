-- =============================================================================
-- Migration 431 — Tighten validate_hire_fields() + add Bank section check
-- =============================================================================
--
-- CHANGES
-- ───────
-- 1. Bank (NEW): employee_bank_account_set must have ≥1 active item
--    (is_active = true) for this employee_id. Checks both the set row and
--    that ≥1 item exists in employee_bank_account_item for that set.
--
-- 2. Personal (tighten): add first_name IS NOT NULL check alongside the
--    existing nationality / gender / dob check.
--
-- 3. Employment (tighten): add dept_id IS NOT NULL alongside the existing
--    designation / hire_date / work_country / work_location check.
--
-- 4. Emergency (tighten): the existing check only requires ≥1 row. Tighten
--    to require name IS NOT NULL AND phone IS NOT NULL on that row.
--    (name is NOT NULL on the table but phone is nullable, so the real new
--    gate is: at least one contact has a non-null phone.)
--
-- WHY NOW
-- ───────
-- The hire pipeline now collects bank accounts (migs 328–332) and the
-- name-split (mig 334) made first_name a meaningful required field.
-- dept_id has always been expected for a valid hire but was never enforced
-- server-side. Emergency contacts with no phone are not useful for HR ops.
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

  -- ── Personal: first_name + nationality + gender + dob ─────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id = p_employee_id
      AND  first_name  IS NOT NULL AND first_name != ''
      AND  nationality IS NOT NULL
      AND  gender      IS NOT NULL
      AND  dob         IS NOT NULL
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
  --               + dept_id ─────────────────────────────────────────────────
  IF v_emp.designation   IS NULL
     OR v_emp.hire_date     IS NULL
     OR v_emp.work_country  IS NULL
     OR v_emp.work_location IS NULL
     OR v_emp.dept_id       IS NULL
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
  'Mig 431: added Bank check; tightened Personal (first_name), '
  'Employment (dept_id), Emergency (phone required).';

-- No REVOKE/GRANT change needed — permissions inherited from mig 260.

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'validate_hire_fields'
  ) THEN
    RAISE EXCEPTION 'ABORT: validate_hire_fields not found after migration 431.';
  END IF;
  RAISE NOTICE 'Migration 431 verified: validate_hire_fields updated.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 431
-- =============================================================================
