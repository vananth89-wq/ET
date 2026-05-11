-- =============================================================================
-- Migration 179: Sent-Back Inbox support
--
-- Two changes:
--
-- 1. vw_wf_my_requests — add wi.metadata column
--    The Sent Back tab in the Workflow Inbox reuses ExpenseEnrichment /
--    ProfileEnrichment, both of which need metadata (name, total_amount,
--    proposed field values, etc.).  The view previously omitted it.
--
-- 2. wf_withdraw — accept 'awaiting_clarification' status
--    Previously wf_withdraw only accepted 'in_progress' instances.
--    When an approver returns a request for clarification the instance
--    status becomes 'awaiting_clarification', so the submitter could not
--    withdraw it even though that is a valid choice.  This patch broadens
--    the guard to accept both statuses.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Rebuild vw_wf_my_requests with metadata
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  wi.metadata,                                -- ← NEW: for Sent Back enrichment
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  -- Current pending task (NULL when completed / returned / rejected)
  current_task.assigned_to   AS current_approver_id,
  e_apr.name                 AS current_approver_name,
  current_task.due_at        AS current_task_due,
  -- Clarification request details (populated when status = 'awaiting_clarification')
  clarif.notes               AS clarification_message,
  e_clarif.name              AS clarification_from,
  clarif.created_at          AS clarification_at
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
-- Current pending task
LEFT JOIN  workflow_tasks      current_task
             ON  current_task.instance_id = wi.id
             AND current_task.step_order  = wi.current_step
             AND current_task.status      = 'pending'
LEFT JOIN  profiles            p_apr ON p_apr.id        = current_task.assigned_to
LEFT JOIN  employees           e_apr ON e_apr.id        = p_apr.employee_id
-- Latest clarification request (most recent returned_to_initiator action)
LEFT JOIN LATERAL (
  SELECT wal.notes, wal.actor_id, wal.created_at
  FROM   workflow_action_log wal
  WHERE  wal.instance_id = wi.id
    AND  wal.action      = 'returned_to_initiator'
  ORDER  BY wal.created_at DESC
  LIMIT  1
) clarif ON true
LEFT JOIN  profiles            p_clarif ON p_clarif.id   = clarif.actor_id
LEFT JOIN  employees           e_clarif ON e_clarif.id   = p_clarif.employee_id
WHERE      wi.submitted_by = auth.uid()
ORDER BY   wi.updated_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'All workflow instances submitted by the current user. Includes current '
  'approver, SLA due date, clarification message when status = awaiting_clarification, '
  'and metadata (added mig 179) for Sent Back inbox enrichment.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Extend wf_withdraw to accept awaiting_clarification
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

  -- Accept both in_progress and awaiting_clarification (mig 179)
  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION
      'wf_withdraw: cannot withdraw — instance status is % (expected in_progress or awaiting_clarification)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- Cancel any pending tasks (none when awaiting_clarification, but safe to run)
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
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, notes)
  VALUES
    (p_instance_id, auth.uid(), 'withdrawn', p_reason);

  -- Sync module back to 'draft' so the user can edit and resubmit
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'draft');
END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid, text) IS
  'Allows the submitter (or admin) to withdraw a workflow instance. '
  'Accepts both in_progress and awaiting_clarification statuses (broadened in mig 179). '
  'Cancels pending tasks and resets the module record to draft status.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_my_requests'
  AND  column_name = 'metadata';

SELECT proname, prosrc LIKE '%awaiting_clarification%' AS accepts_clarification
FROM   pg_proc
WHERE  proname = 'wf_withdraw';

-- =============================================================================
-- END OF MIGRATION 179
-- =============================================================================
