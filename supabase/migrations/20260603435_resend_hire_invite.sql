-- =============================================================================
-- Migration 434 — resend_hire_invite(p_employee_id)
-- =============================================================================
--
-- PROBLEM
-- ───────
-- When wf_activate_employee fires, it records an employee_invites row and
-- stamps employees.invite_sent_at. If the email bounces or expires there is no
-- HR-facing action — recovery requires a developer action in the Supabase dashboard.
--
-- FIX
-- ───
-- SECURITY DEFINER RPC that:
--   1. Guards: employee must be status = 'Active'
--   2. Guards: must have a business_email
--   3. Guards: no linked auth account yet
--      (profiles row with employee_id = p_employee_id AND id IS NOT NULL means
--       the user already signed in — resend not needed / not allowed)
--   4. Records the resend in employee_invites (increments attempt_no)
--   5. Stamps employees.invite_sent_at = NOW()
--   6. Returns { ok: true, email: '...' } so the frontend can fire signInWithOtp
--
-- The actual OTP/magic-link dispatch stays on the client (supabase.auth.signInWithOtp)
-- consistent with the existing invite flow in RoleAssignments.tsx.
-- =============================================================================

CREATE OR REPLACE FUNCTION resend_hire_invite(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_emp         employees%ROWTYPE;
  v_next_attempt int;
  v_has_auth    boolean;
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

  -- ── 5. Must NOT already have a linked auth account ────────────────────────
  -- A profile row exists and is linked → user already accepted the invite.
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE  employee_id = p_employee_id
      AND  id IS NOT NULL
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
    'ok',    true,
    'email', v_emp.business_email,
    'name',  v_emp.name,
    'attempt_no', v_next_attempt
  );
END;
$$;

REVOKE ALL    ON FUNCTION resend_hire_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resend_hire_invite(uuid) TO authenticated;

COMMENT ON FUNCTION resend_hire_invite(uuid) IS
  'Guard + audit for re-sending a hire invite. '
  'Checks: Active status, has business_email, no linked auth account. '
  'Increments employee_invites attempt_no and stamps invite_sent_at. '
  'Returns { ok, email, name, attempt_no } — frontend fires signInWithOtp. '
  'Mig 434.';


-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'resend_hire_invite'
  ) THEN
    RAISE EXCEPTION 'ABORT: resend_hire_invite missing.';
  END IF;
  RAISE NOTICE 'Migration 434 verified: resend_hire_invite present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 434
-- =============================================================================
