-- =============================================================================
-- Migration 122: Auto-advance CC steps in wf_advance_instance and wf_submit
--
-- PROBLEM
-- ───────
-- Migration 093 added is_cc to workflow_steps and wf_add_step(), but never
-- updated the workflow engine. CC steps were treated identically to approval
-- steps — they created a pending task that required human action.
--
-- CORRECT BEHAVIOUR
-- ─────────────────
-- A CC step should:
--   1. Create the task (so audit trail exists)
--   2. Send the notification (that is its purpose)
--   3. Auto-approve the task immediately (no human action required)
--   4. Advance to the next step
--
-- CHANGES
-- ───────
-- 1. wf_advance_instance — after creating the task, if the step is CC:
--      auto-approve, log 'cc_notified', call wf_advance_instance recursively.
--      Notification code now resolves via workflow_notification_templates if
--      step.notification_template_id is set; falls back to 'wf.task_assigned'.
--      (Today all steps have notification_template_id = NULL — behaviour identical.
--       When custom notification templates UI is built, steps can be assigned one.)
-- 2. wf_submit — after creating the first task, if the first step is CC:
--      auto-approve, log 'cc_notified', call wf_advance_instance.
--      All other logic unchanged from mig 121.
--
-- SAFETY
-- ──────
-- Recursive CC chains are safe: each call advances current_step before
-- recursing, so wf_advance_instance always looks for steps AFTER current.
-- The recursion terminates at the first non-CC step or when all steps complete.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Replace wf_advance_instance — add CC auto-advance
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_advance_instance(
  p_instance_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance     RECORD;
  v_next_step    RECORD;
  v_approver_id  uuid;
  v_due_at       timestamptz;
  v_new_task_id  uuid;
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- Find the next active step after current (skip wf_evaluate_skip_step steps)
  SELECT ws.*
  INTO   v_next_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  > v_instance.current_step
    AND  ws.is_active   = true
    AND  NOT wf_evaluate_skip_step(ws.id, v_instance.metadata)
  ORDER  BY ws.step_order
  LIMIT  1;

  IF NOT FOUND THEN
    -- ── All steps done — complete the instance ────────────────────────────
    UPDATE workflow_instances
    SET    status       = 'approved',
           updated_at   = now(),
           completed_at = now()
    WHERE  id = p_instance_id;

    INSERT INTO workflow_action_log
      (instance_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
       'All approval steps completed');

    -- Notify the submitter
    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.completed',
      v_instance.submitted_by,
      jsonb_build_object('module_code', v_instance.module_code)
    );

    -- Sync module record status
    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');

    RETURN;
  END IF;

  -- ── Resolve approver for next step ────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    -- Cannot route — warn and stall. Admins can reassign.
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance %',
                  v_next_step.step_order, p_instance_id;
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;
    RETURN;
  END IF;

  -- ── Compute SLA deadline (skipped for CC steps) ───────────────────────────
  v_due_at := CASE
    WHEN v_next_step.is_cc      THEN NULL  -- CC steps have no SLA
    WHEN v_next_step.sla_hours IS NOT NULL
    THEN now() + (v_next_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create task for next step ─────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  -- Advance current_step on the instance
  UPDATE workflow_instances
  SET    current_step = v_next_step.step_order,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Notify assignee / CC recipient ───────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    COALESCE(
      (SELECT wnt.code FROM workflow_notification_templates wnt
       WHERE wnt.id = v_next_step.notification_template_id),
      'wf.task_assigned'
    ),
    v_approver_id,
    jsonb_build_object(
      'step_name',  v_next_step.name,
      'module_code', v_instance.module_code
    )
  );

  -- ── CC step: auto-complete, then advance again ────────────────────────────
  IF v_next_step.is_cc THEN
    UPDATE workflow_tasks
    SET    status   = 'approved',
           acted_at = now(),
           notes    = 'CC — auto-notified'
    WHERE  id = v_new_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, v_new_task_id, auth.uid(), 'cc_notified',
       v_next_step.step_order, 'CC step — notification sent, auto-completed');

    -- Recurse to the next step (safe: current_step already updated above)
    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ── Regular step: log the transition and stop ─────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES
    (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

END;
$$;

COMMENT ON FUNCTION wf_advance_instance(uuid) IS
  'Advances a workflow instance to the next active, non-skipped step. '
  'CC steps (is_cc=true) are auto-completed: notification sent, task marked approved, '
  'then recursively advances to the next step. Migration 122.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Replace wf_submit — add CC auto-advance for the first step
--    Full body from migration 121 + CC handling after first task creation.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template    RECORD;
  v_first_step  RECORD;
  v_instance_id uuid;
  v_task_id     uuid;
  v_approver_id uuid;
  v_due_at      timestamptz;
BEGIN
  -- ── Validate template (module_code check removed — templates are module-agnostic) ──
  SELECT id, version, is_active
  INTO   v_template
  FROM   workflow_templates
  WHERE  code      = p_template_code
    AND  is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: template % not found or inactive', p_template_code;
  END IF;

  -- ── Guard: no active workflow already running for this record ─────────────
  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      = 'in_progress'
  ) THEN
    RAISE EXCEPTION 'wf_submit: an active workflow already exists for this record';
  END IF;

  -- ── Find first step (skip auto-skip steps) ────────────────────────────────
  SELECT ws.*
  INTO   v_first_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_template.id
    AND  ws.is_active   = true
    AND  NOT wf_evaluate_skip_step(ws.id, p_metadata)
  ORDER  BY ws.step_order
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: no active steps found in template %', p_template_code;
  END IF;

  -- ── Create instance ───────────────────────────────────────────────────────
  INSERT INTO workflow_instances
    (template_id, template_version, module_code, record_id,
     submitted_by, current_step, status, metadata)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata)
  RETURNING id INTO v_instance_id;

  -- ── Resolve approver for step 1 ───────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_submit: cannot resolve approver for step 1 of template %',
                    p_template_code;
  END IF;

  -- ── SLA deadline (skipped for CC steps) ──────────────────────────────────
  v_due_at := CASE
    WHEN v_first_step.is_cc     THEN NULL
    WHEN v_first_step.sla_hours IS NOT NULL
    THEN now() + (v_first_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create first task ─────────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_task_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, metadata)
  VALUES
    (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
     jsonb_build_object('template_code', p_template_code));

  -- ── Notify first approver / CC recipient ─────────────────────────────────
  PERFORM wf_queue_notification(
    v_instance_id,
    'wf.task_assigned',
    v_approver_id,
    jsonb_build_object(
      'step_name',   v_first_step.name,
      'module_code', p_module_code
    )
  );

  -- ── CC step: auto-complete and advance to next step ───────────────────────
  IF v_first_step.is_cc THEN
    UPDATE workflow_tasks
    SET    status   = 'approved',
           acted_at = now(),
           notes    = 'CC — auto-notified'
    WHERE  id = v_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (v_instance_id, v_task_id, auth.uid(), 'cc_notified',
       v_first_step.step_order, 'CC step — notification sent, auto-completed');

    PERFORM wf_advance_instance(v_instance_id);
    RETURN v_instance_id;
  END IF;

  -- ── Sync module status to 'submitted' ─────────────────────────────────────
  PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Starts a new workflow instance. Templates are module-agnostic (migration 118). '
  'CC first steps are auto-completed and advanced immediately (migration 122). '
  'All original logic preserved: SLA, audit log, notification, status sync.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname FROM pg_proc
WHERE  proname IN ('wf_advance_instance', 'wf_submit')
ORDER  BY proname;
