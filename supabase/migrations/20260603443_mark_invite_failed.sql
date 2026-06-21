-- =============================================================================
-- Migration 443 — mark_invite_failed(p_employee_id, p_error)
-- =============================================================================
--
-- PROBLEM (G-D)
-- ─────────────
-- resend_hire_invite() records the attempt in employee_invites (status='sent')
-- and returns { ok, email } before the frontend fires signInWithOtp(). If the
-- OTP call fails, attempt_no has already been incremented and invite_sent_at
-- stamped — but no email was actually delivered. The audit record is wrong.
--
-- FIX
-- ───
-- SECURITY DEFINER RPC called by the frontend when signInWithOtp() errors.
-- Updates the latest employee_invites row for this employee to status='failed'
-- and records the error message. Idempotent — safe to call multiple times.
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_invite_failed(
  p_employee_id uuid,
  p_error       text DEFAULT 'OTP dispatch failed'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only the HR user who just called resend_hire_invite (or a super admin)
  -- should be able to mark an invite as failed.
  IF NOT (user_can('hire_employee', 'edit', NULL) OR is_super_admin()) THEN
    RAISE EXCEPTION 'mark_invite_failed: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Update the most recent 'sent' row for this employee to 'failed'.
  UPDATE employee_invites
  SET    status        = 'failed',
         error_message = p_error,
         updated_at    = NOW()
  WHERE  id = (
    SELECT id FROM employee_invites
    WHERE  employee_id = p_employee_id
      AND  status      = 'sent'
    ORDER  BY attempt_no DESC
    LIMIT  1
  );
  -- No error if no matching row — the invite row may have already been
  -- updated or the call is a duplicate. Silent no-op is correct.
END;
$$;

REVOKE ALL    ON FUNCTION mark_invite_failed(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mark_invite_failed(uuid, text) TO authenticated;

COMMENT ON FUNCTION mark_invite_failed(uuid, text) IS
  'Called by the frontend when signInWithOtp() fails after resend_hire_invite() '
  'succeeded. Updates the latest sent employee_invites row to status=failed and '
  'records the error message so the audit trail reflects actual delivery. Mig 443.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'mark_invite_failed'
  ) THEN
    RAISE EXCEPTION 'ABORT: mark_invite_failed missing.';
  END IF;
  RAISE NOTICE 'Migration 443 verified: mark_invite_failed present.';
END;
$$;
