-- Migration 269: Rejected hire → Sent Back inbox flow
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- ───────
-- When an approver rejects a hire:
--   1. employee.status was set to 'Incomplete' — indistinguishable from a send-back.
--   2. The rejected hire appeared in My Requests with a "Remove Record" button that
--      called acknowledge_rejected_hire() (soft-delete, no workflow context).
--   3. The initiator had no way to read the rejection reason in a unified inbox view.
--
-- DESIGN
-- ──────
-- Rejected hires should flow through the same Sent Back inbox as send-backs:
--   1. Rejection → employee.status = 'Rejected' (new enum value), employee.locked = true.
--   2. vw_wf_my_requests clarification lateral picks up 'rejected' action notes so the
--      rejection reason surfaces in the inbox card preview.
--   3. useMySentBackItems queries status IN ('awaiting_clarification', 'rejected').
--   4. Initiator reads rejection reason in the Sent Back panel, then clicks Withdraw.
--   5. wf_withdraw now accepts 'rejected' instances — soft-deletes employee and
--      transitions instance to 'withdrawn', removing it from the inbox.
--
-- CHANGES
-- ───────
-- 1. ALTER TYPE employee_status ADD VALUE 'Rejected'
-- 2. wf_sync_module_status: employee_hire + rejected → status='Rejected', locked=true
-- 3. vw_wf_my_requests: clarif lateral action IN ('returned_to_initiator','rejected')
-- 4. wf_withdraw: accept 'rejected' status; skip task-cancel (no-op); still call
--    wf_sync_module_status('draft') → soft-delete
-- ─────────────────────────────────────────────────────────────────────────────


-- ════════════════════════════════════════════════════════════════════════════
-- Step 1: Add 'Rejected' to employee_status enum
-- ════════════════════════════════════════════════════════════════════════════

ALTER TYPE employee_status ADD VALUE IF NOT EXISTS 'Rejected';

-- Commit the enum change so it is visible in the same transaction
-- (Postgres requires this for enums added within the same session before use)
-- Note: In Supabase migrations each file runs in its own transaction, so
-- the new value is immediately available to subsequent DDL in this file.


-- ════════════════════════════════════════════════════════════════════════════
-- Step 2: Update wf_sync_module_status
--   employee_hire + rejected: was Incomplete (identical to send-back).
--   Now sets status = 'Rejected' and locked = true so the form is read-only
--   and the employee is visually distinct from a sent-back hire.
-- ════════════════════════════════════════════════════════════════════════════

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
          ELSE status
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Employee Hire ──────────────────────────────────────────────────────────
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status = 'approved' THEN
      PERFORM wf_activate_employee(p_record_id);

    ELSIF p_status = 'submitted' THEN
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'rejected' THEN
      -- Hard rejection → lock the record and set Rejected status so the
      -- form is read-only and visually distinct from a sent-back (Incomplete) hire.
      -- The initiator will see this in the Sent Back inbox, read the reason,
      -- then Withdraw (which calls wf_sync_module_status('draft') → soft-delete).
      UPDATE employees
      SET    status     = 'Rejected',
             locked     = true,
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
      -- Initiator withdrew (or discarded a rejected) hire → soft-delete.
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
  'profile_*: maps engine statuses → wpc CHECK values. '
  'employee_hire: '
  '  approved            → wf_activate_employee. '
  '  submitted           → Pending + locked. '
  '  rejected            → Rejected + locked=true (mig 269: was Incomplete). '
  '  awaiting_clarification → Incomplete + unlocked. '
  '  draft (withdraw)    → soft-delete (deleted_at = now()), guard: status ≠ Active. '
  'Mig 245: full canonical restore. Mig 269: rejected → Rejected enum value.';


-- ════════════════════════════════════════════════════════════════════════════
-- Step 3: Rebuild vw_wf_my_requests
--   The clarification lateral join now picks up BOTH 'returned_to_initiator'
--   and 'rejected' action log entries so rejection reasons surface in the
--   Sent Back inbox card preview (clarification_message column).
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  COALESCE(wpc.proposed_data, wi.metadata)  AS metadata,
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  current_task.assigned_to   AS current_approver_id,
  e_apr.name                 AS current_approver_name,
  current_task.due_at        AS current_task_due,
  -- Clarification / rejection details:
  --   awaiting_clarification → latest 'returned_to_initiator' action notes
  --   rejected               → latest 'rejected' action notes
  --   Both share the same columns so the inbox card renders the same way.
  clarif.notes               AS clarification_message,
  e_clarif.name              AS clarification_from,
  clarif.created_at          AS clarification_at
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
LEFT JOIN  workflow_pending_changes wpc ON wpc.id = wi.record_id
LEFT JOIN  workflow_tasks      current_task
             ON  current_task.instance_id = wi.id
             AND current_task.step_order  = wi.current_step
             AND current_task.status      = 'pending'
LEFT JOIN  profiles            p_apr ON p_apr.id        = current_task.assigned_to
LEFT JOIN  employees           e_apr ON e_apr.id        = p_apr.employee_id
-- Latest clarification OR rejection note
LEFT JOIN LATERAL (
  SELECT wal.notes, wal.actor_id, wal.created_at
  FROM   workflow_action_log wal
  WHERE  wal.instance_id = wi.id
    AND  wal.action      IN ('returned_to_initiator', 'rejected')
  ORDER  BY wal.created_at DESC
  LIMIT  1
) clarif ON true
LEFT JOIN  profiles            p_clarif ON p_clarif.id   = clarif.actor_id
LEFT JOIN  employees           e_clarif ON e_clarif.id   = p_clarif.employee_id
WHERE      wi.submitted_by = auth.uid()
ORDER BY   wi.updated_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'All workflow instances submitted by the current user. '
  'metadata (mig 199): COALESCE(wpc.proposed_data, wi.metadata). '
  'clarification_message (mig 269): picks up both returned_to_initiator AND '
  'rejected action notes so rejection reasons appear in the Sent Back inbox.';


-- ════════════════════════════════════════════════════════════════════════════
-- Step 4: Extend wf_withdraw — accept 'rejected' instances
--
-- Rejected workflow instances are terminal but the initiator still needs a
-- path to clean up (soft-delete) the pre-hire employee record.  Previously
-- this was handled by acknowledge_rejected_hire().  Now wf_withdraw is the
-- universal withdrawal path for all non-active module records.
--
-- Behaviour for rejected instances:
--   • Task cancellation: no-op (all tasks already cancelled/rejected by engine)
--   • Instance status: rejected → withdrawn (clean audit trail)
--   • Audit log: 'withdrawn' with optional p_reason
--   • wf_sync_module_status('draft'): soft-deletes the employee record
--
-- acknowledge_rejected_hire() is left in place for backward compatibility
-- but its UI surface (the "Remove Record" button) has been removed.
-- ════════════════════════════════════════════════════════════════════════════

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

  -- Accept all three non-terminal active states:
  --   in_progress            — normal in-flight withdrawal
  --   awaiting_clarification — withdrawing after a send-back
  --   rejected               — initiator discarding a hard-rejected hire
  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification', 'rejected') THEN
    RAISE EXCEPTION
      'wf_withdraw: only in_progress, awaiting_clarification, or rejected instances '
      'can be withdrawn (current status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- Cancel any remaining pending tasks.
  -- No-op for awaiting_clarification (tasks already 'returned') and
  -- rejected (tasks already 'cancelled' / 'rejected' by the engine).
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
  'Allows the submitter (or admin) to withdraw a workflow request. '
  'Mig 245: extended from in_progress-only to also accept awaiting_clarification. '
  'Mig 269: also accepts rejected so initiators can discard hard-rejected hires '
  'from the Sent Back inbox (replaces the acknowledge_rejected_hire UI path). '
  'Cancels pending tasks (no-op for sent-back/rejected), marks instance withdrawn, '
  'and syncs module record via wf_sync_module_status(draft).';


-- ════════════════════════════════════════════════════════════════════════════
-- Step 5: Backfill existing rejected hires
--   Before this migration, wf_sync_module_status set status='Incomplete' for
--   rejected hires.  Any employee whose workflow instance is already in the
--   'rejected' terminal state should have status='Rejected' + locked=true so
--   they surface correctly in AddEmployee's "New Hires in Progress" table and
--   get the proper red badge instead of "Incomplete".
-- ════════════════════════════════════════════════════════════════════════════

UPDATE employees e
SET    status     = 'Rejected',
       locked     = true,
       updated_at = now()
FROM   workflow_instances wi
WHERE  wi.module_code = 'employee_hire'
  AND  wi.record_id   = e.id::text
  AND  wi.status      = 'rejected'
  AND  e.status       = 'Incomplete'
  AND  e.deleted_at  IS NULL;

-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'wf_sync_module_status'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_sync_module_status not found after migration 269.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'wf_withdraw'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_withdraw not found after migration 269.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.views
    WHERE  table_schema = 'public'
      AND  table_name   = 'vw_wf_my_requests'
  ) THEN
    RAISE EXCEPTION 'ABORT: vw_wf_my_requests not found after migration 269.';
  END IF;

  RAISE NOTICE 'Migration 269 verified: employee_status.Rejected + wf_sync_module_status + wf_withdraw + vw_wf_my_requests updated.';
END;
$$;
