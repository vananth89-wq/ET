-- =============================================================================
-- Migration 252: get_hire_submission_mode + wf_activate_employee workflow guard
--
-- PROBLEM
-- ───────
-- The frontend (AddEmployee.tsx) determines whether to show "Submit for Approval"
-- or "Activate Employee" by querying workflow_assignments directly. The backend
-- uses resolve_workflow_for_submission() for the same decision. These two paths
-- can drift:
--   • Direct query ignores EMPLOYEE > ROLE > GLOBAL priority resolution.
--   • If the frontend shows "Activate" but the backend has a workflow configured,
--     wf_activate_employee bypasses approval silently.
--
-- FIX
-- ───
-- 1. get_hire_submission_mode() — single RPC that wraps resolve_workflow_for_submission
--    for employee_hire. Returns 'workflow' or 'direct'. The frontend calls this
--    to determine which button to render, using the exact same logic the backend
--    uses when deciding whether to allow a submission.
--
-- 2. wf_activate_employee() guard (mig 251 updated) — if called when a workflow
--    IS configured (and the call is not coming from the engine), raise an error
--    so the UI path and the server path are mutually enforcing.
--    Engine path detection: wf_advance_instance sets instance.status='approved'
--    BEFORE calling wf_sync_module_status → wf_activate_employee, so an approved
--    instance already exists when we reach this check.
--
-- BUSINESS RULE
-- ─────────────
-- • Workflow configured for employee_hire → "Submit for Approval" only.
--   Direct activate is blocked at both the UI layer (button hidden) and the
--   server layer (wf_activate_employee raises an exception).
-- • No workflow configured → "Activate Employee" only.
--   submit_hire() already raises an actionable error when no workflow exists.
-- • Mid-flight records (locked = true, active instance exists) are unaffected —
--   the instance must complete through the engine regardless of current config.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — get_hire_submission_mode()
-- ════════════════════════════════════════════════════════════════════════════
--
-- Wraps resolve_workflow_for_submission so the frontend and backend use
-- exactly the same assignment-resolution logic (EMPLOYEE > ROLE > GLOBAL,
-- effective-date filter). Returns 'workflow' or 'direct'.
--
-- Access: any authenticated user with hire_employee.view can call this.
-- (Same minimum permission needed to open AddEmployee.)

CREATE OR REPLACE FUNCTION get_hire_submission_mode()
RETURNS text    -- 'workflow' | 'direct'
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
    RETURN 'workflow';
  END IF;
  RETURN 'direct';
END;
$$;

COMMENT ON FUNCTION get_hire_submission_mode() IS
  'Returns ''workflow'' if an active workflow assignment is configured for '
  'employee_hire (resolved via resolve_workflow_for_submission for the calling user), '
  'or ''direct'' if no workflow is configured. '
  'The frontend uses this to show the correct action button; '
  'wf_activate_employee uses the same logic to guard the direct-activate path. '
  'Mig 252.';

REVOKE ALL   ON FUNCTION get_hire_submission_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_hire_submission_mode() TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — wf_activate_employee: add workflow guard
-- ════════════════════════════════════════════════════════════════════════════
--
-- Replaces the version from mig 251.
-- New behaviour at Step 4:
--   Engine path  (approved instance exists)  → skip guard, no notification needed
--                                               (hire.completed already delivered)
--   Direct path  (no approved instance)      → check if workflow is configured.
--     Workflow IS configured  → RAISE EXCEPTION (block direct-activate)
--     Workflow NOT configured → allow; insert notification to auth.uid()

CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_employee_id   text;
  v_next_attempt  int;
  v_has_instance  boolean;
BEGIN
  -- ── Fetch employee ────────────────────────────────────────────────────────
  SELECT status::text, business_email, name, employee_id
  INTO   v_status, v_email, v_name, v_employee_id
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  -- ── Step 1: Activate the employee record ──────────────────────────────────
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 2: Record invite attempt ─────────────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  -- ── Step 3: Stamp invite_sent_at ─────────────────────────────────────────
  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 4: Engine-path vs. direct-path detection ─────────────────────────
  --
  -- wf_advance_instance sets instance.status = 'approved' BEFORE calling
  -- wf_sync_module_status → wf_activate_employee. So when we reach here via
  -- the engine, an approved instance already exists for this employee.
  --
  -- If no approved instance exists, this is the direct-activate path.
  -- In that case we enforce the business rule: direct activate is only permitted
  -- when NO workflow is configured for employee_hire.
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    -- ── Guard: block direct-activate when a workflow is configured ────────────
    IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
      RAISE EXCEPTION
        'A workflow approval process is configured for New Hire. '
        'Please use "Submit for Approval" instead of activating directly. '
        'Direct activation is only available when no workflow is configured.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- ── No workflow configured — direct-activate is intentional ─────────────
    -- Notify auth.uid() so there is an audit trail in the notification bell.
    -- (wf_queue_notification requires an instance_id; we insert directly here.)
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      auth.uid(),
      'Employee activated: ' || v_name,
      v_name || ' (' || COALESCE(v_employee_id, '—') || ') has been directly '
        || 'activated (no approval workflow configured). '
        || 'The invite record has been created.',
      '/employees'
    );
  END IF;

  -- NOTE: Auth OTP (signInWithOtp) and link_profile_to_employee must be
  -- called from the frontend after this RPC returns, because they require
  -- the Supabase client SDK / service-role key.
END;
$$;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-approved employee: sets status=Active, locked=false, records invite. '
  'Mig 252 guard: if called in the direct-activate path (no approved workflow instance) '
  'AND a workflow is configured for employee_hire, raises insufficient_privilege — '
  'direct activation is blocked; caller must use submit_hire instead. '
  'If no workflow is configured, direct activation is permitted and a notification is '
  'written to auth.uid() for audit trail. '
  'Engine path (approved instance already exists): no guard, no duplicate notification '
  '— hire.completed was already delivered by wf_advance_instance. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL   ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'get_hire_submission_mode'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_hire_submission_mode not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'wf_activate_employee'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_activate_employee not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 252 verified: get_hire_submission_mode and wf_activate_employee present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 252
--
-- After this migration:
--   Frontend calls get_hire_submission_mode() → 'workflow' | 'direct'
--   • 'workflow' → show "Submit for Approval", hide "Activate Employee"
--   • 'direct'   → show "Activate Employee", hide "Submit for Approval"
--
--   wf_activate_employee enforces the same rule server-side:
--   • Workflow configured + direct call → exception (use submit_hire)
--   • No workflow + direct call         → allowed, notification written
--   • Called from engine (approved instance exists) → no guard, no dup notif
--
--   Frontend must update AddEmployee.tsx to call get_hire_submission_mode()
--   instead of querying workflow_assignments directly (see task #84).
-- =============================================================================
