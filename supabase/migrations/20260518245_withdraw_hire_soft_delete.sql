-- =============================================================================
-- Migration 245: Withdraw hire → soft delete
--
-- PROBLEMS FIXED
-- ──────────────
-- 1. wf_sync_module_status regression (mig 224)
--    Migration 224 added the employee_hire branch but accidentally dropped:
--      a) expense_reports.approved_at / approved_by logic (from mig 173)
--      b) the entire profile_* branch (from mig 173)
--    This migration restores both and adds the employee_hire 'draft' handler.
--
-- 2. wf_withdraw only accepted status = 'in_progress'
--    Sent-back items have status = 'awaiting_clarification'.  The Withdraw
--    button in the Sent Back tab was therefore broken for ALL modules.
--    Extended to also accept 'awaiting_clarification'.
--
-- 3. No soft-delete path for rejected hires
--    After a hard reject the workflow instance is terminal ('rejected') so
--    wf_withdraw cannot touch it.  New function acknowledge_rejected_hire()
--    soft-deletes the employee record for initiators who want to close out
--    a rejected hire.
--
-- EMPLOYEE SOFT-DELETE BEHAVIOUR
-- ───────────────────────────────
-- employees.deleted_at is already defined in the initial schema (mig 001).
-- employees_select RLS already filters deleted_at IS NULL.
-- All satellite-table RLS policies (employee_personal, employee_contact, etc.)
-- already join employees and check deleted_at IS NULL (mig 219/220).
-- So setting deleted_at on the parent row automatically hides all child data
-- with no additional policy changes required.
--
-- Only pre-activation employees (status ≠ 'Active') can be soft-deleted.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Restore wf_sync_module_status — full canonical version
--
-- Incorporates:
--   mig 162  — profile_* branch (draft → withdrawn)
--   mig 173  — expense approved_at/approved_by + profile_* status mapping
--   mig 224  — employee_hire branch
--   THIS MIG  — employee_hire 'draft' handler (soft delete on withdraw)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
BEGIN

  -- ── Expense Reports ────────────────────────────────────────────────────────
  -- Restore approved_at / approved_by that mig 224 accidentally dropped.
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles
      WHERE  id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  -- Restored after mig 224 dropped this branch entirely.
  -- p_record_id = workflow_pending_changes.id
  -- Maps engine statuses → valid CHECK values for wpc.status:
  --   ('pending', 'approved', 'rejected', 'withdrawn')
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'   THEN 'pending'
          WHEN 'in_progress' THEN 'pending'
          WHEN 'draft'       THEN 'withdrawn'
          WHEN 'cancelled'   THEN 'withdrawn'
          WHEN 'approved'    THEN 'approved'
          WHEN 'rejected'    THEN 'rejected'
          WHEN 'withdrawn'   THEN 'withdrawn'
          ELSE status   -- no-op for unknown statuses
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Employee Hire ──────────────────────────────────────────────────────────
  -- From mig 224 + new 'draft' handler (wf_withdraw → soft delete).
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status = 'approved' THEN
      -- Final approval → activate (sets Active + locked=false + invite record).
      -- Frontend must still send the OTP magic-link (Supabase Auth cannot be
      -- called from PostgreSQL).
      PERFORM wf_activate_employee(p_record_id);

    ELSIF p_status = 'submitted' THEN
      -- Resubmit after send-back → re-lock while in review.
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'rejected' THEN
      -- Hard rejection → unlock so HR can fix data and start a new submission.
      -- Status resets to Incomplete (form data preserved, not Draft).
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'awaiting_clarification' THEN
      -- Sent back for clarification → unlock so HR can edit inline.
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'draft' THEN
      -- Initiator withdrew the hire request → soft-delete the pre-hire record.
      -- Guard: never delete an Active employee (should not be reachable, but
      -- belt-and-suspenders).
      UPDATE employees
      SET    deleted_at = now(),
             updated_at = now()
      WHERE  id      = p_record_id
        AND  status != 'Active';

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for employee_hire — record unchanged',
        p_status;
    END IF;

  -- ── Future modules ─────────────────────────────────────────────────────────
  -- Add ELSIF p_module_code = 'leave_requests' THEN … for each new module.
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Syncs the source module record after a workflow engine event. '
  'expense_reports: sets status/approved_at/approved_by. '
  'profile_*: maps engine statuses → wpc CHECK values (submitted/in_progress→pending, '
  '  draft/cancelled→withdrawn, approved/rejected pass-through). '
  'employee_hire: '
  '  approved → wf_activate_employee. '
  '  submitted → Pending + locked. '
  '  rejected → Incomplete + unlocked. '
  '  awaiting_clarification → Incomplete + unlocked. '
  '  draft (withdraw) → soft-delete (deleted_at = now()), guard: status ≠ Active. '
  'Mig 070: approved_at/approved_by. Mig 161: profile_* branch. '
  'Mig 162: draft→withdrawn. Mig 173: submitted/in_progress→pending. '
  'Mig 224: employee_hire branch. Mig 245: expense regression fix, profile_* '
  'regression fix, employee_hire draft→soft-delete.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Extend wf_withdraw — accept awaiting_clarification
--
-- Previously only 'in_progress' was accepted.  Sent-back items have
-- status = 'awaiting_clarification', so the Withdraw button was broken for
-- ALL modules in the Sent Back tab.  Now both statuses are permitted.
--
-- When status = 'awaiting_clarification':
--   • No pending tasks exist (wf_return_to_initiator already set them to
--     'returned'), so the task-cancel UPDATE is a safe no-op.
--   • Instance is marked 'withdrawn' and wf_sync_module_status is called
--     exactly as before — for employee_hire this triggers the soft delete
--     added in Step 1.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_withdraw(
  p_instance_id uuid,
  p_reason      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  SELECT id, submitted_by, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_withdraw: instance % not found', p_instance_id;
  END IF;

  -- Allow withdrawal from either active state:
  --   in_progress            — normal in-flight withdrawal
  --   awaiting_clarification — withdrawing after a send-back
  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION
      'wf_withdraw: only in_progress or awaiting_clarification instances can be '
      'withdrawn (current status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- Cancel any remaining pending tasks (no-op when status = awaiting_clarification
  -- since those tasks are already 'returned').
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- Mark instance withdrawn
  UPDATE workflow_instances
  SET    status       = 'withdrawn',
         updated_at   = now(),
         completed_at = now()
  WHERE  id = p_instance_id;

  -- Audit
  INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
  VALUES (p_instance_id, auth.uid(), 'withdrawn', p_reason);

  -- Sync module record:
  --   expense_reports → reset to 'draft' (editable again)
  --   profile_*       → set wpc.status = 'withdrawn'
  --   employee_hire   → soft-delete (deleted_at = now())
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'draft');
END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid, text) IS
  'Allows the submitter (or admin) to withdraw an in-progress or sent-back '
  'workflow request. Cancels any pending tasks, marks the instance withdrawn, '
  'and syncs the module record via wf_sync_module_status. '
  'Mig 245: extended from in_progress-only to also accept awaiting_clarification '
  'so the Sent Back tab Withdraw button works for all modules.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: acknowledge_rejected_hire — soft-delete after hard rejection
--
-- wf_withdraw cannot touch terminal instances (status = 'rejected').
-- This function provides a dedicated path for the initiator to close out a
-- hard-rejected hire by soft-deleting the employee record.
--
-- Authorization:
--   PATH A — caller submitted the rejected workflow instance for this employee
--   PATH B — caller holds hire_employee.edit (HR Head / admin)
--
-- Guard: employee must not be Active (belt-and-suspenders; a rejected employee
--        should never be Active, but we guard explicitly).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION acknowledge_rejected_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
BEGIN
  -- Guard 1: caller must be the workflow submitter or hold hire_employee.edit
  IF NOT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'rejected'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION
      'Not authorised to acknowledge rejection for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Guard 2: employee must exist and must not be Active
  SELECT status::text INTO v_status
  FROM   employees
  WHERE  id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'Cannot soft-delete an Active employee record (employee %).',
      p_employee_id;
  END IF;

  -- Soft-delete
  UPDATE employees
  SET    deleted_at = now(),
         updated_at = now()
  WHERE  id = p_employee_id;
END;
$$;

COMMENT ON FUNCTION acknowledge_rejected_hire(uuid) IS
  'Soft-deletes a pre-hire employee record after the workflow instance was '
  'hard-rejected (status = rejected). Distinct from wf_withdraw because '
  'terminal instances cannot be touched by wf_withdraw. '
  'Guard 1: caller must be the original submitter of the rejected instance '
  'or hold hire_employee.edit. '
  'Guard 2: employee must not be Active (prevents accidental deletion). '
  'Sets employees.deleted_at = now(); satellite data becomes invisible via '
  'existing RLS policies which all check deleted_at IS NULL.';

REVOKE ALL ON FUNCTION acknowledge_rejected_hire(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION acknowledge_rejected_hire(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Confirm all three functions exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'wf_sync_module_status'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_sync_module_status not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'wf_withdraw'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_withdraw not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'acknowledge_rejected_hire'
  ) THEN
    RAISE EXCEPTION 'ABORT: acknowledge_rejected_hire not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 245 verified: all three functions present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 245
--
-- After this migration:
--   wf_sync_module_status  → full canonical version (all 3 module branches)
--   wf_withdraw            → accepts in_progress + awaiting_clarification
--   acknowledge_rejected_hire → new; soft-deletes rejected pre-hire records
--
-- Regression fixes from mig 224:
--   expense_reports.approved_at / approved_by restored
--   profile_* status mapping branch restored
-- =============================================================================
