-- =============================================================================
-- Migration 216: wf_reassign_step — collapse multi-approver fan-out to one person
--
-- PROBLEM
-- ───────
-- When an admin reassigns a ROLE fan-out step (e.g. Finance has Hari A +
-- Naveen Elango), using wf_bulk_reassign reassigns EVERY task to the new
-- person. The new person ends up with 2 pending tasks at the same step.
--
-- FIX
-- ───
-- New function wf_reassign_step: atomically collapses all pending tasks at
-- (instance_id, step_order) to a single task for the new assignee.
--
--   • Reassigns the earliest pending task to p_new_profile_id
--   • Marks any additional tasks at that step as 'force_advanced'
--     (same status used when the admin skips a task via force advance)
--   • Notifies original holders of removed tasks
--   • Notifies the new assignee
--   • Writes a single 'reassigned' audit log entry
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_reassign_step(
  p_instance_id    uuid,
  p_step_order     integer,
  p_new_profile_id uuid,
  p_reason         text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance      RECORD;
  v_task          RECORD;
  v_kept_task_id  uuid;
BEGIN
  -- ── Access check ────────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_reassign_step: insufficient permissions';
  END IF;

  -- ── Load instance ───────────────────────────────────────────────────────────
  SELECT id, module_code, submitted_by
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reassign_step: instance % not found', p_instance_id;
  END IF;

  -- ── Validate new assignee ───────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = p_new_profile_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'wf_reassign_step: new assignee is not an active user';
  END IF;

  -- ── Process all pending tasks at this step ──────────────────────────────────
  -- Keep the first (oldest) task, reassign it. Cancel the rest.
  FOR v_task IN
    SELECT id, assigned_to
    FROM   workflow_tasks
    WHERE  instance_id = p_instance_id
      AND  step_order  = p_step_order
      AND  status      = 'pending'
    ORDER  BY created_at
    FOR UPDATE
  LOOP
    IF v_kept_task_id IS NULL THEN
      -- Keep this task: reassign to the new person
      v_kept_task_id := v_task.id;
      UPDATE workflow_tasks
      SET    assigned_to = p_new_profile_id
      WHERE  id = v_task.id;
    ELSE
      -- Cancel extra task: same status as a force-advanced bypass
      UPDATE workflow_tasks
      SET    status   = 'force_advanced',
             notes    = COALESCE(p_reason, 'Step reassigned to a single approver'),
             acted_at = now()
      WHERE  id = v_task.id;

      -- Notify original holder that their task was removed
      PERFORM wf_queue_notification(
        p_instance_id,
        'wf.task_removed',
        v_task.assigned_to,
        jsonb_build_object(
          'step_order', p_step_order,
          'reason',     COALESCE(p_reason, 'Step reassigned to a single approver')
        )
      );
    END IF;
  END LOOP;

  IF v_kept_task_id IS NULL THEN
    RAISE EXCEPTION 'wf_reassign_step: no pending tasks found at step %', p_step_order;
  END IF;

  -- ── Notify new assignee ─────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.task_assigned',
    p_new_profile_id,
    jsonb_build_object(
      'step_order',  p_step_order,
      'module_code', v_instance.module_code
    )
  );

  -- ── Audit log ───────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    p_instance_id,
    v_kept_task_id,
    auth.uid(),
    'reassigned',
    p_step_order,
    p_reason,
    jsonb_build_object(
      'new_assignee_id', p_new_profile_id,
      'reason',          p_reason
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_reassign_step(uuid, integer, uuid, text) IS
  'Admin-only: collapse all pending tasks at a step to a single assignee. '
  'Extra tasks (from ROLE fan-out) are marked force_advanced. '
  'Use instead of wf_bulk_reassign when the intent is to replace all approvers '
  'at a step with one specific person.';

REVOKE ALL     ON FUNCTION wf_reassign_step(uuid, integer, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_reassign_step(uuid, integer, uuid, text) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 216
-- =============================================================================
