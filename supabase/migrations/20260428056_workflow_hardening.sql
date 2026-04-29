-- =============================================================================
-- Migration 056: Workflow Hardening
--
-- Fixes confirmed gaps from gap analysis:
--
--   1. wf_approve / wf_reject — add has_permission('workflow.admin') to the
--      admin bypass so workflow.admin users are treated consistently with
--      has_role('admin') across all RPCs.
--
--   2. wf_reassign — restore delegation chain following (was present in
--      migration 047 but dropped when migration 050 replaced the function).
--      Also adds has_permission('workflow.admin') to the permission check.
--
--   3. get_workflow_summary / get_step_bottlenecks — add permission guards.
--      Only get_approver_performance had one; the other two were readable
--      by any authenticated user (unintended data exposure).
--
--   4. workflow_steps.approver_type CHECK constraint — add 'SELF' which is
--      handled in wf_resolve_approver but was missing from the constraint,
--      making it impossible to INSERT a SELF-approver step.
--
--   5. Missing index — workflow_instances(status) partial index for
--      'awaiting_clarification' to speed up KPI queries in Operations screen.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. wf_approve — add has_permission('workflow.admin') to admin bypass
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_approve(
  p_task_id uuid,
  p_notes   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_approve: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_approve: task is not pending (current status: %)', v_task.status;
  END IF;

  -- Allow assigned approver OR any admin/workflow.admin to approve
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_approve: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_approve: workflow instance is not active (status: %)', v_instance.status;
  END IF;

  -- Mark task approved
  UPDATE workflow_tasks
  SET    status   = 'approved',
         notes    = p_notes,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Audit log
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'approved', v_task.step_order, p_notes);

  -- Advance instance
  PERFORM wf_advance_instance(v_task.instance_id);
END;
$$;

COMMENT ON FUNCTION wf_approve(uuid, text) IS
  'Approves a pending workflow task. Callable by the assigned approver or any '
  'user with admin role / workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_reject — add has_permission('workflow.admin') to admin bypass
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_reject(
  p_task_id uuid,
  p_reason  text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_reject: a rejection reason is required';
  END IF;

  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reject: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_reject: task is not pending (current status: %)', v_task.status;
  END IF;

  -- Allow assigned approver OR any admin/workflow.admin to reject
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_reject: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, submitted_by, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_reject: workflow instance is not active (status: %)', v_instance.status;
  END IF;

  -- Mark task rejected
  UPDATE workflow_tasks
  SET    status   = 'rejected',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Cancel all other pending tasks on this instance
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = v_task.instance_id
    AND  status      = 'pending'
    AND  id          != p_task_id;

  -- Mark instance rejected
  UPDATE workflow_instances
  SET    status       = 'rejected',
         completed_at = now(),
         updated_at   = now()
  WHERE  id = v_task.instance_id;

  -- Sync module record status
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'rejected');

  -- Audit log
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'rejected', v_task.step_order, p_reason);

  -- Notify submitter
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.rejected',
    v_instance.submitted_by,
    jsonb_build_object('reason', p_reason, 'step_order', v_task.step_order)
  );
END;
$$;

COMMENT ON FUNCTION wf_reject(uuid, text) IS
  'Rejects a pending workflow task, cancels the instance, and notifies the submitter. '
  'Callable by the assigned approver or any user with admin role / workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_reassign — restore delegation chain following + add workflow.admin
--
--    Restores the logic from migration 047 (which migration 050 overwrote):
--    when reassigning to user X, if X has an active delegation to Y and the
--    step allows delegation, the task is routed to Y (up to 5 hops).
--    Admin/workflow.admin users bypass the ownership check.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_reassign(
  p_task_id        uuid,
  p_new_profile_id uuid,
  p_reason         text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task               RECORD;
  v_new_task           uuid;
  v_step_allow_deleg   boolean;
  v_final_assignee     uuid;
  v_chain_depth        integer := 0;
  v_chain_max CONSTANT integer := 5;
  v_next_delegate      uuid;
BEGIN
  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status, t.due_at
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reassign: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_reassign: only pending tasks can be reassigned (current: %)', v_task.status;
  END IF;

  -- Caller must be the assignee, OR have admin role/permission
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_reassign: you cannot reassign this task';
  END IF;

  -- Look up whether this step permits delegation
  SELECT COALESCE(allow_delegation, true)
  INTO   v_step_allow_deleg
  FROM   workflow_steps
  WHERE  id = v_task.step_id;

  -- Follow delegation chain on the intended assignee (if step allows it)
  v_final_assignee := p_new_profile_id;

  IF v_step_allow_deleg THEN
    LOOP
      v_chain_depth := v_chain_depth + 1;
      EXIT WHEN v_chain_depth > v_chain_max;

      SELECT delegate_id INTO v_next_delegate
      FROM   workflow_delegations
      WHERE  delegator_id  = v_final_assignee
        AND  is_active     = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL)   -- all-template delegations only when no context
      ORDER  BY from_date DESC
      LIMIT  1;

      EXIT WHEN v_next_delegate IS NULL;
      v_final_assignee := v_next_delegate;
    END LOOP;
  END IF;

  -- Mark old task reassigned
  UPDATE workflow_tasks
  SET    status   = 'reassigned',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Audit log (records both intended and final assignee for full transparency)
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(), 'reassigned',
    v_task.step_order, p_reason,
    jsonb_build_object(
      'from_profile',        v_task.assigned_to,
      'to_profile',          p_new_profile_id,
      'final_assignee',      v_final_assignee,
      'delegation_applied',  (v_final_assignee != p_new_profile_id)
    )
  );

  -- Create new task for final assignee
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, status, due_at)
  VALUES
    (v_task.instance_id, v_task.step_id, v_task.step_order,
     v_final_assignee, 'pending', v_task.due_at)
  RETURNING id INTO v_new_task;

  -- Notify new assignee
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.task_assigned',
    v_final_assignee,
    jsonb_build_object(
      'step_order', v_task.step_order,
      'reassigned', true
    )
  );

  -- Notify old assignee if someone else reassigned them
  IF v_task.assigned_to != auth.uid() THEN
    PERFORM wf_queue_notification(
      v_task.instance_id,
      'wf.task_removed',
      v_task.assigned_to,
      jsonb_build_object(
        'step_order', v_task.step_order,
        'reason',     COALESCE(p_reason, 'Task reassigned by admin')
      )
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_reassign(uuid, uuid, text) IS
  'Reassigns a pending task to a new approver, following active delegation chains '
  'if the step allows delegation. Callable by the task owner or admin/workflow.admin. '
  'Restores delegation chain logic from migration 047.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. get_workflow_summary + get_step_bottlenecks — add permission guards
--    Must DROP first because the RETURNS TABLE definition changed.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS get_workflow_summary(timestamptz, timestamptz, text);
DROP FUNCTION IF EXISTS get_step_bottlenecks(timestamptz, timestamptz, text);

CREATE OR REPLACE FUNCTION get_workflow_summary(
  p_from          timestamptz DEFAULT now() - interval '30 days',
  p_to            timestamptz DEFAULT now(),
  p_template_code text        DEFAULT NULL
)
RETURNS TABLE (
  template_code         text,
  template_name         text,
  total_submitted       bigint,
  total_approved        bigint,
  total_rejected        bigint,
  total_in_progress     bigint,
  avg_completion_hours  numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'get_workflow_summary: insufficient permissions';
  END IF;

  RETURN QUERY
  SELECT
    tpl.code,
    tpl.name,
    COUNT(*)                                                                AS total_submitted,
    COUNT(*) FILTER (WHERE wi.status = 'approved')                         AS total_approved,
    COUNT(*) FILTER (WHERE wi.status = 'rejected')                         AS total_rejected,
    COUNT(*) FILTER (WHERE wi.status IN ('in_progress','awaiting_clarification')) AS total_in_progress,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1
    )                                                                       AS avg_completion_hours
  FROM  workflow_instances wi
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  WHERE wi.created_at >= p_from
    AND wi.created_at <= p_to
    AND (p_template_code IS NULL OR tpl.code = p_template_code)
  GROUP BY tpl.code, tpl.name
  ORDER BY total_submitted DESC;
END;
$$;

COMMENT ON FUNCTION get_workflow_summary(timestamptz, timestamptz, text) IS
  'Returns aggregate workflow metrics per template. Requires admin or workflow.admin.';


CREATE OR REPLACE FUNCTION get_step_bottlenecks(
  p_from          timestamptz DEFAULT now() - interval '30 days',
  p_to            timestamptz DEFAULT now(),
  p_template_code text        DEFAULT NULL
)
RETURNS TABLE (
  template_code      text,
  template_name      text,
  step_order         integer,
  step_name          text,
  sla_hours          integer,
  total_tasks        bigint,
  avg_duration_hours numeric,
  overdue_count      bigint,
  rejection_rate_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'get_step_bottlenecks: insufficient permissions';
  END IF;

  RETURN QUERY
  SELECT
    tpl.code,
    tpl.name,
    ws.step_order,
    ws.name,
    ws.sla_hours,
    COUNT(*)                                                               AS total_tasks,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (COALESCE(wt.acted_at, now()) - wt.created_at)) / 3600.0), 1
    )                                                                      AS avg_duration_hours,
    COUNT(*) FILTER (WHERE wt.status = 'pending' AND wt.due_at < now())   AS overdue_count,
    ROUND(
      100.0 * COUNT(*) FILTER (WHERE wt.status = 'rejected')
      / NULLIF(COUNT(*) FILTER (WHERE wt.status IN ('approved','rejected')), 0), 1
    )                                                                      AS rejection_rate_pct
  FROM  workflow_tasks     wt
  JOIN  workflow_instances wi  ON wi.id  = wt.instance_id
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  JOIN  workflow_steps     ws  ON ws.id  = wt.step_id
  WHERE wi.created_at >= p_from
    AND wi.created_at <= p_to
    AND (p_template_code IS NULL OR tpl.code = p_template_code)
    AND wt.status NOT IN ('skipped', 'cancelled')
  GROUP BY tpl.code, tpl.name, ws.step_order, ws.name, ws.sla_hours
  ORDER BY tpl.code, ws.step_order;
END;
$$;

COMMENT ON FUNCTION get_step_bottlenecks(timestamptz, timestamptz, text) IS
  'Returns per-step duration and rejection metrics. Requires admin or workflow.admin.';


-- ════════════════════════════════════════════════════════════════════════════
-- 5. workflow_steps.approver_type — add 'SELF' to CHECK constraint
-- ════════════════════════════════════════════════════════════════════════════

-- PostgreSQL doesn't support ALTER TABLE ... ALTER CONSTRAINT directly.
-- We must drop and re-add the constraint.

ALTER TABLE workflow_steps
  DROP CONSTRAINT IF EXISTS workflow_steps_approver_type_check;

ALTER TABLE workflow_steps
  ADD CONSTRAINT workflow_steps_approver_type_check
  CHECK (approver_type IN (
    'MANAGER',        -- submitter's line manager
    'ROLE',           -- any user with approver_role
    'DEPT_HEAD',      -- submitter's department head
    'SPECIFIC_USER',  -- fixed profile (approver_profile_id)
    'RULE_BASED',     -- evaluate workflow_step_conditions
    'SELF'            -- submitter self-approves (no delegation)
  ));

COMMENT ON COLUMN workflow_steps.approver_type IS
  'Who resolves the approver for this step. SELF = submitter self-approves '
  '(useful for acknowledgement steps).';


-- ════════════════════════════════════════════════════════════════════════════
-- 6. Missing index: workflow_instances status = 'awaiting_clarification'
-- ════════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS wf_instances_awaiting_clarification_idx
  ON workflow_instances (status, updated_at DESC)
  WHERE status = 'awaiting_clarification';

COMMENT ON INDEX wf_instances_awaiting_clarification_idx IS
  'Speeds up KPI query for "Awaiting Submitter" count in Operations screen.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm RPCs updated
SELECT proname FROM pg_proc
WHERE  proname IN ('wf_approve','wf_reject','wf_reassign',
                   'get_workflow_summary','get_step_bottlenecks')
ORDER  BY proname;

-- Confirm constraint updated
SELECT constraint_name, check_clause
FROM   information_schema.check_constraints
WHERE  constraint_name = 'workflow_steps_approver_type_check';

-- Confirm index created
SELECT indexname FROM pg_indexes
WHERE  tablename = 'workflow_instances'
  AND  indexname = 'wf_instances_awaiting_clarification_idx';
