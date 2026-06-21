-- Migration 255: Queue hire.withdrawn notification from wf_withdraw
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- The hire.withdrawn template was seeded in mig 250 but wf_withdraw (mig 245)
-- never calls wf_queue_notification — so approvers receive no alert when an
-- initiator withdraws a hire request.
--
-- SOLUTION
-- Patch wf_withdraw to:
--   1. Collect the assignee UUIDs of pending tasks BEFORE cancelling them.
--   2. After cancelling + syncing module status, send hire.withdrawn to each
--      collected assignee (only when module_code = 'employee_hire').
--
-- No schema changes — pure RPC replacement.
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
  v_instance   RECORD;
  v_assignee   uuid;
  v_assignees  uuid[];
BEGIN
  SELECT id, submitted_by, module_code, reference_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_withdraw: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION
      'wf_withdraw: only in_progress or awaiting_clarification instances can be '
      'withdrawn (current status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- ── Collect pending assignees before cancelling (for notifications) ────────
  -- Only collect for employee_hire — other modules don't have a withdrawn template.
  IF v_instance.module_code = 'employee_hire' THEN
    SELECT array_agg(DISTINCT assignee_id)
    INTO   v_assignees
    FROM   workflow_tasks
    WHERE  instance_id = p_instance_id
      AND  status      = 'pending'
      AND  assignee_id IS NOT NULL;
  END IF;

  -- ── Cancel any remaining pending tasks ─────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- ── Mark instance withdrawn ────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'withdrawn',
         updated_at   = now(),
         completed_at = now()
  WHERE  id = p_instance_id;

  -- ── Audit ──────────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
  VALUES (p_instance_id, auth.uid(), 'withdrawn', p_reason);

  -- ── Sync module record ─────────────────────────────────────────────────────
  --   expense_reports → reset to 'draft'
  --   profile_*       → set wpc.status = 'withdrawn'
  --   employee_hire   → soft-delete (deleted_at = now())
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.reference_id, 'draft');

  -- ── Notify approvers (employee_hire only) ──────────────────────────────────
  IF v_instance.module_code = 'employee_hire' AND v_assignees IS NOT NULL THEN
    FOREACH v_assignee IN ARRAY v_assignees LOOP
      PERFORM wf_queue_notification(
        p_instance_id,
        'hire.withdrawn',
        v_assignee,
        '{}'::jsonb
      );
    END LOOP;
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid, text) IS
  'Allows the submitter (or admin) to withdraw an in-progress or sent-back '
  'workflow request. Cancels any pending tasks, marks the instance withdrawn, '
  'and syncs the module record via wf_sync_module_status. '
  'Mig 245: extended from in_progress-only to also accept awaiting_clarification. '
  'Mig 255: queues hire.withdrawn notification to each pending approver on '
  'employee_hire withdrawals.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE  proname = 'wf_withdraw'
      AND  pronargs = 2
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_withdraw not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM workflow_notification_templates WHERE code = 'hire.withdrawn'
  ) THEN
    RAISE EXCEPTION 'ABORT: hire.withdrawn template missing — apply mig 250 first.';
  END IF;
END;
$$;
