-- =============================================================================
-- Migration 515 — Fix resend_hire_invite auth account guard
--
-- PROBLEM
-- ───────
-- The guard in resend_hire_invite checks:
--   SELECT EXISTS (SELECT 1 FROM profiles WHERE employee_id = p_employee_id AND id IS NOT NULL)
-- A profiles row always has a non-NULL id (it's a UUID PK), so this check
-- fires true even when no matching auth.users row exists — blocking the resend
-- for employees who genuinely have no login account.
--
-- FIX
-- ───
-- Check auth.users directly by email instead of relying on the profiles row.
-- =============================================================================

CREATE OR REPLACE FUNCTION resend_hire_invite(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_emp          employees%ROWTYPE;
  v_next_attempt int;
  v_has_auth     boolean;
BEGIN
  -- ── 1. Permission gate ────────────────────────────────────────────────────
  IF NOT (user_can('hire_employee', 'edit', NULL) OR is_super_admin()) THEN
    RAISE EXCEPTION 'resend_hire_invite: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 2. Load employee ──────────────────────────────────────────────────────
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'resend_hire_invite: employee % not found', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- ── 3. Must be Active ─────────────────────────────────────────────────────
  IF v_emp.status != 'Active' THEN
    RAISE EXCEPTION 'resend_hire_invite: employee is not Active (status: %)',
                    v_emp.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 4. Must have a business email ─────────────────────────────────────────
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    RAISE EXCEPTION 'resend_hire_invite: employee has no business email'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 5. Must NOT already have a real auth.users account ───────────────────
  -- Previously checked profiles.id IS NOT NULL which is always true.
  -- Now checks auth.users directly by email — the only reliable source.
  SELECT EXISTS (
    SELECT 1 FROM auth.users
    WHERE lower(email) = lower(v_emp.business_email)
  ) INTO v_has_auth;

  IF v_has_auth THEN
    RAISE EXCEPTION
      'resend_hire_invite: employee already has an active auth account — resend not needed'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 6. Record the resend attempt ──────────────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── 7. Return email so frontend can fire signInWithOtp ────────────────────
  RETURN jsonb_build_object(
    'ok',         true,
    'email',      v_emp.business_email,
    'name',       v_emp.name,
    'attempt_no', v_next_attempt
  );
END;
$$;

REVOKE ALL    ON FUNCTION resend_hire_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resend_hire_invite(uuid) TO authenticated;

COMMENT ON FUNCTION resend_hire_invite(uuid) IS
  'Guard + audit for re-sending a hire invite. '
  'Checks: Active status, has business_email, no auth.users row for the email. '
  'Mig 434: initial. Mig 515: fixed auth check — now queries auth.users by email '
  'instead of profiles.id IS NOT NULL (which was always true).';

-- =============================================================================
-- VERIFICATION
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'resend_hire_invite'
  ) THEN
    RAISE EXCEPTION 'ABORT: resend_hire_invite missing.';
  END IF;
  RAISE NOTICE 'Migration 515 verified: resend_hire_invite auth check fixed.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 515
-- =============================================================================
