-- =============================================================================
-- Workflow Return Actions
--
-- Adds three new approver actions:
--
--   wf_return_to_initiator(p_task_id, p_message)
--     Approver sends the request back to the submitter for clarification.
--     Instance pauses (awaiting_clarification). Submitter gets a notification
--     with the approver's message. Workflow resumes via wf_resubmit().
--
--   wf_resubmit(p_instance_id, p_response DEFAULT NULL)
--     Submitter responds to a clarification request and restarts the workflow
--     from the same step. A new task is created for the original approver.
--
--   wf_return_to_previous_step(p_task_id, p_reason DEFAULT NULL)
--     Approver sends the workflow back to the previous approval step.
--     The previous approver gets a new pending task. Current task is closed.
--     Only valid when current step > 1.
--
-- Schema changes:
--   workflow_instances.status  → adds 'awaiting_clarification'
--   workflow_tasks.status      → adds 'returned'
--   vw_wf_my_requests          → rebuilt to expose clarification details
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Extend CHECK constraints
-- ════════════════════════════════════════════════════════════════════════════

-- workflow_instances.status: add 'awaiting_clarification'
ALTER TABLE workflow_instances
  DROP CONSTRAINT IF EXISTS workflow_instances_status_check;
ALTER TABLE workflow_instances
  ADD CONSTRAINT workflow_instances_status_check
  CHECK (status IN (
    'submitted', 'in_progress', 'approved', 'rejected',
    'withdrawn', 'cancelled', 'awaiting_clarification'
  ));

-- workflow_tasks.status: add 'returned'
ALTER TABLE workflow_tasks
  DROP CONSTRAINT IF EXISTS workflow_tasks_status_check;
ALTER TABLE workflow_tasks
  ADD CONSTRAINT workflow_tasks_status_check
  CHECK (status IN (
    'pending', 'approved', 'rejected', 'reassigned',
    'returned', 'skipped', 'cancelled'
  ));

-- Notification templates for new actions
INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  ('wf.clarification_requested',
   'Clarification needed on your request',
   'An approver has requested clarification before proceeding. Message: {{message}}'),
  ('wf.clarification_submitted',
   'Submitter has responded — request back in your inbox',
   'The submitter has responded to your clarification request. Their response: {{response}}'),
  ('wf.returned_to_previous_step',
   'Approval request returned to previous step',
   'A request you approved has been returned to your step for re-review. Reason: {{reason}}')
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — wf_return_to_initiator
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_return_to_initiator(
  p_task_id uuid,
  p_message text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  -- ── Validate inputs ────────────────────────────────────────────────────────
  IF p_message IS NULL OR trim(p_message) = '' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: a clarification message is required';
  END IF;

  -- ── Load and lock task ─────────────────────────────────────────────────────
  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_return_to_initiator: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: task is not pending (current: %)', v_task.status;
  END IF;

  IF v_task.assigned_to != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_return_to_initiator: you are not assigned to this task';
  END IF;

  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT id, submitted_by, status, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: instance is not in progress (status: %)',
                    v_instance.status;
  END IF;

  -- ── Mark task returned ─────────────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'returned',
         notes    = p_message,
         acted_at = now()
  WHERE  id = p_task_id;

  -- ── Pause the instance ─────────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status     = 'awaiting_clarification',
         updated_at = now()
  WHERE  id = v_task.instance_id;

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes,
     metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(),
    'returned_to_initiator',
    v_task.step_order,
    p_message,
    jsonb_build_object('step_id', v_task.step_id)
  );

  -- ── Notify the submitter ───────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.clarification_requested',
    v_instance.submitted_by,
    jsonb_build_object('message', p_message)
  );
END;
$$;

COMMENT ON FUNCTION wf_return_to_initiator(uuid, text) IS
  'Approver returns a request to the submitter for clarification. '
  'Instance is paused (awaiting_clarification). Submitter must call '
  'wf_resubmit() to resume the workflow from the same step.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — wf_resubmit
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id uuid,
  p_response    text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance     RECORD;
  v_step         RECORD;
  v_approver_id  uuid;
  v_due_at       timestamptz;
  v_new_task_id  uuid;
BEGIN
  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT id, submitted_by, status, current_step, template_id, module_code, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION 'wf_resubmit: instance is not awaiting clarification (status: %)',
                    v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_resubmit: only the original submitter can resubmit';
  END IF;

  -- ── Find the current step definition ───────────────────────────────────────
  SELECT ws.id, ws.step_order, ws.name, ws.sla_hours
  INTO   v_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  = v_instance.current_step
    AND  ws.is_active   = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: step % not found for template',
                    v_instance.current_step;
  END IF;

  -- ── Resolve approver (respects delegation) ─────────────────────────────────
  v_approver_id := wf_resolve_approver(v_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_resubmit: could not resolve an approver for step %',
                    v_instance.current_step;
  END IF;

  -- ── Resume instance ────────────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status     = 'in_progress',
         updated_at = now()
  WHERE  id = p_instance_id;

  -- ── Compute SLA deadline ───────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_step.sla_hours IS NOT NULL
    THEN now() + (v_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create new pending task for the approver ───────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_step.id, v_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id, v_new_task_id, auth.uid(),
    'resubmitted',
    v_instance.current_step,
    COALESCE(p_response, 'Submitter resubmitted after clarification.')
  );

  -- ── Notify the approver ────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.clarification_submitted',
    v_approver_id,
    jsonb_build_object(
      'response', COALESCE(p_response, ''),
      'step_name', v_step.name
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_resubmit(uuid, text) IS
  'Submitter responds to a clarification request and resumes the workflow. '
  'Instance status returns to in_progress. A new pending task is created for '
  'the approver at the current step (delegation rules re-applied).';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — wf_return_to_previous_step
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_return_to_previous_step(
  p_task_id uuid,
  p_reason  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task        RECORD;
  v_instance    RECORD;
  v_prev_step   RECORD;
  v_approver_id uuid;
  v_due_at      timestamptz;
  v_new_task_id uuid;
BEGIN
  -- ── Load and lock task ─────────────────────────────────────────────────────
  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to, t.status, t.due_at
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: task is not pending (current: %)',
                    v_task.status;
  END IF;

  IF v_task.assigned_to != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: you are not assigned to this task';
  END IF;

  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT id, template_id, submitted_by, status, current_step, module_code, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: instance is not in progress (status: %)',
                    v_instance.status;
  END IF;

  IF v_task.step_order <= 1 THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: cannot go back from step 1 — use Return to Submitter instead';
  END IF;

  -- ── Find the previous active step (highest step_order < current) ───────────
  -- Uses the action log to find the most-recently approved step, which handles
  -- skipped steps correctly (we go back to what was actually executed).
  SELECT ws.*
  INTO   v_prev_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.is_active   = true
    AND  ws.step_order  < v_task.step_order
    AND  EXISTS (
      SELECT 1 FROM workflow_action_log wal
      WHERE  wal.instance_id = v_task.instance_id
        AND  wal.step_order  = ws.step_order
        AND  wal.action      = 'approved'
    )
  ORDER  BY ws.step_order DESC
  LIMIT  1;

  IF NOT FOUND THEN
    -- Fallback: just take the highest active step below current
    SELECT ws.*
    INTO   v_prev_step
    FROM   workflow_steps ws
    WHERE  ws.template_id = v_instance.template_id
      AND  ws.is_active   = true
      AND  ws.step_order  < v_task.step_order
    ORDER  BY ws.step_order DESC
    LIMIT  1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: no previous step found';
  END IF;

  -- ── Resolve approver for the previous step (delegation re-applied) ─────────
  v_approver_id := wf_resolve_approver(v_prev_step.id, v_task.instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: could not resolve approver for step %',
                    v_prev_step.step_order;
  END IF;

  -- ── Mark current task as returned ─────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'returned',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- ── Roll instance back to previous step ───────────────────────────────────
  UPDATE workflow_instances
  SET    current_step = v_prev_step.step_order,
         updated_at   = now()
  WHERE  id = v_task.instance_id;

  -- ── Compute SLA for the re-opened step ────────────────────────────────────
  v_due_at := CASE
    WHEN v_prev_step.sla_hours IS NOT NULL
    THEN now() + (v_prev_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create new pending task for the previous step's approver ──────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_task.instance_id, v_prev_step.id, v_prev_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  -- Log against the ORIGINAL task (p_task_id) — the task that was returned.
  -- v_new_task_id is the newly created task for the previous approver; it is
  -- captured in metadata for traceability, but the causal event belongs to the
  -- task that was acted on, consistent with wf_approve / wf_reject / wf_reassign.
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes,
     metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(),
    'returned_to_previous_step',
    v_task.step_order,          -- the step that triggered the return (not prev step)
    COALESCE(p_reason, 'Returned to previous step for re-review.'),
    jsonb_build_object(
      'from_step',    v_task.step_order,
      'to_step',      v_prev_step.step_order,
      'new_task_id',  v_new_task_id           -- reference to the new task created
    )
  );

  -- ── Notify the previous approver ──────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.returned_to_previous_step',
    v_approver_id,
    jsonb_build_object(
      'reason',    COALESCE(p_reason, ''),
      'from_step', v_task.step_order,
      'to_step',   v_prev_step.step_order
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_return_to_previous_step(uuid, text) IS
  'Returns a workflow to the previous approval step. The previous approver '
  'receives a new pending task with re-applied delegation rules. '
  'Only valid when current step > 1. Uses the action log to find the '
  'most-recently approved step (handles skipped steps correctly).';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 5 — Rebuild vw_wf_my_requests to expose clarification details
--
-- Adds three new columns:
--   clarification_message  — the approver's question (from action log)
--   clarification_from     — display name of who asked
--   clarification_at       — when it was requested
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
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
  'approver, SLA due date, and clarification message when status = awaiting_clarification.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 6 — Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'wf_return_to_initiator',
  'wf_resubmit',
  'wf_return_to_previous_step'
)
ORDER BY proname;

SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_my_requests'
  AND  column_name IN ('clarification_message', 'clarification_from', 'clarification_at');
