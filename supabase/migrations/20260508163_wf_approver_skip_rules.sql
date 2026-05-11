-- =============================================================================
-- Migration 163: Approver step removal — initiator & template-level duplicate
--
-- WHAT THIS MIGRATION DOES
-- ─────────────────────────
-- Silently removes steps from a workflow instance when they should not be
-- processed. "Removed" means: no workflow_tasks row is created, the step is
-- completely invisible to users, and the workflow advances as if the step
-- never existed.
--
-- This is distinct from "skip" (migration 164), where a task IS created with
-- status='skipped' and appears visibly in the Activity feed.
--
-- REMOVAL RULES
-- ─────────────
-- Rule 1 — Initiator-as-approver removal (always active, no flag needed):
--   If the resolved approver for any step equals the workflow submitter
--   (submitted_by), that step is silently removed. An employee cannot approve
--   their own request via any routing path. No task created, no notification.
--
-- Rule 2 — Consecutive duplicate approver removal (template flag):
--   Requires workflow_templates.remove_duplicate_approver = true.
--
--   LOOK-AHEAD, KEEP-LAST logic:
--   Step N is removed when:
--     (a) A next step N+1 exists (this is NOT the last step), AND
--     (b) The resolved approver for step N+1 = the resolved approver for step N
--
--   Effect: in a chain [user1, user1, user1, user2] steps 1 and 2 are silently
--   removed; step 3 (last user1) is kept. The approver sees exactly one task
--   per consecutive run, at the final position in that run.
--
--   The last step is NEVER removed by Rule 2 (look-ahead finds nothing).
--
-- AUDIT
-- ─────
-- Removed steps leave a lightweight workflow_action_log entry with
-- action = 'step_removed' and task_id = NULL. No workflow_tasks row is created.
-- This lets admins understand why step numbers are non-consecutive in the log,
-- without exposing removed steps to end users.
--
-- SCHEMA CHANGES
-- ──────────────
-- workflow_templates: ADD COLUMN remove_duplicate_approver boolean DEFAULT false
--
-- FUNCTION CHANGES
-- ────────────────
-- wf_advance_instance : Rule 1 + Rule 2 removal after wf_resolve_approver()
-- wf_submit           : Rule 1 + Rule 2 removal for the first step
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Schema
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_templates
  ADD COLUMN IF NOT EXISTS remove_duplicate_approver boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN workflow_templates.remove_duplicate_approver IS
  'When true: any step whose resolved approver matches the NEXT step''s approver '
  'is silently removed — no workflow_tasks row is created, the step is invisible '
  'to end users. Look-ahead keep-last: the last step is never removed. '
  'See skip_duplicate_approver (mig 164) for the visible skip variant. '
  'Migration 163.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_advance_instance — Rule 1 + Rule 2 removal
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_advance_instance(
  p_instance_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance            RECORD;
  v_next_step           RECORD;
  v_approver_id         uuid;
  v_due_at              timestamptz;
  v_new_task_id         uuid;
  -- Removal logic
  v_remove_dup          boolean := false;
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
  v_remove_reason       text;   -- NULL = no removal; non-NULL = remove with this reason
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- Find the next active, non-condition-skipped step after current
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

    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.completed',
      v_instance.submitted_by,
      jsonb_build_object('module_code', v_instance.module_code)
    );

    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');
    RETURN;
  END IF;

  -- ── Resolve approver for this step ────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance %',
                  v_next_step.step_order, p_instance_id;
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;
    RETURN;
  END IF;

  -- ── Removal Rule 1: initiator-as-approver ────────────────────────────────
  -- Always active. The workflow submitter cannot approve their own request.
  IF v_approver_id = v_instance.submitted_by THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  -- ── Removal Rule 2: consecutive duplicate approver (look-ahead, keep-last)
  -- Requires template.remove_duplicate_approver = true.
  -- Step N is removed when step N+1 resolves to the same approver.
  -- The last step is never removed (look-ahead finds nothing → condition false).
  IF v_remove_reason IS NULL THEN
    SELECT remove_duplicate_approver INTO v_remove_dup
    FROM   workflow_templates
    WHERE  id = v_instance.template_id;

    IF v_remove_dup THEN
      SELECT ws2.*
      INTO   v_lookahead_step
      FROM   workflow_steps ws2
      WHERE  ws2.template_id = v_instance.template_id
        AND  ws2.step_order  > v_next_step.step_order
        AND  ws2.is_active   = true
        AND  NOT wf_evaluate_skip_step(ws2.id, v_instance.metadata)
      ORDER  BY ws2.step_order
      LIMIT  1;

      IF FOUND THEN
        v_lookahead_approver := wf_resolve_approver(v_lookahead_step.id, p_instance_id);
        IF v_lookahead_approver IS NOT NULL AND v_lookahead_approver = v_approver_id THEN
          v_remove_reason :=
            'Step removed: same approver appears in next step (remove_duplicate_approver=true)';
        END IF;
      END IF;
    END IF;
  END IF;

  -- ── Execute removal — advance silently, no task created ───────────────────
  IF v_remove_reason IS NOT NULL THEN
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    -- Lightweight audit entry (no task_id — step was never assigned to anyone)
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, NULL, auth.uid(), 'step_removed',
       v_next_step.step_order, v_remove_reason);

    -- No notification — step is invisible to users
    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ── Compute SLA deadline (none for CC steps) ──────────────────────────────
  v_due_at := CASE
    WHEN v_next_step.is_cc      THEN NULL
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
      'step_name',   v_next_step.name,
      'module_code', v_instance.module_code
    )
  );

  -- ── CC step: auto-complete, then advance ─────────────────────────────────
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

    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ── Regular step: log and stop ────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES
    (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

END;
$$;

COMMENT ON FUNCTION wf_advance_instance(uuid) IS
  'Advances a workflow instance to the next active, non-condition-skipped step. '
  'Removal Rule 1 (mig 163): approver = submitter → step silently removed, no task. '
  'Removal Rule 2 (mig 163): remove_duplicate_approver=true AND next step has same '
  'approver → step silently removed, no task (look-ahead keep-last). '
  'CC steps auto-completed with notification (mig 122). '
  'Visible skip (status=skipped) added in mig 164.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_submit — Rule 1 + Rule 2 removal for the first step
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
  v_template            RECORD;
  v_first_step          RECORD;
  v_instance_id         uuid;
  v_task_id             uuid;
  v_approver_id         uuid;
  v_due_at              timestamptz;
  -- Removal logic
  v_remove_reason       text;
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
BEGIN
  -- ── Validate template ─────────────────────────────────────────────────────
  SELECT id, version, is_active, remove_duplicate_approver
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

  -- ── Find first step (skip condition-based steps) ──────────────────────────
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

  -- ── Removal Rule 1: initiator-as-approver ────────────────────────────────
  IF v_approver_id = auth.uid() THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  -- ── Removal Rule 2: look-ahead duplicate (step 1) ────────────────────────
  -- Only fires when remove_duplicate_approver = true AND step 2 exists.
  -- Single-step templates: look-ahead finds nothing → Rule 2 does not fire.
  IF v_remove_reason IS NULL AND v_template.remove_duplicate_approver THEN
    SELECT ws2.*
    INTO   v_lookahead_step
    FROM   workflow_steps ws2
    WHERE  ws2.template_id = v_template.id
      AND  ws2.step_order  > v_first_step.step_order
      AND  ws2.is_active   = true
      AND  NOT wf_evaluate_skip_step(ws2.id, p_metadata)
    ORDER  BY ws2.step_order
    LIMIT  1;

    IF FOUND THEN
      v_lookahead_approver := wf_resolve_approver(v_lookahead_step.id, v_instance_id);
      IF v_lookahead_approver IS NOT NULL AND v_lookahead_approver = v_approver_id THEN
        v_remove_reason :=
          'Step removed: same approver appears in next step (remove_duplicate_approver=true)';
      END IF;
    END IF;
  END IF;

  -- ── Execute removal for step 1 — no task, advance silently ───────────────
  IF v_remove_reason IS NOT NULL THEN
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (v_instance_id, NULL, auth.uid(), 'step_removed', v_first_step.step_order,
       v_remove_reason);

    -- Sync module status to 'submitted' even though step 1 was removed —
    -- the record is now in-flight and must reflect that to the UI.
    PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
    PERFORM wf_advance_instance(v_instance_id);
    RETURN v_instance_id;
  END IF;

  -- ── SLA deadline ─────────────────────────────────────────────────────────
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

  -- ── Notify first approver ─────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_instance_id,
    'wf.task_assigned',
    v_approver_id,
    jsonb_build_object(
      'step_name',   v_first_step.name,
      'module_code', p_module_code
    )
  );

  -- ── CC step: auto-complete and advance ───────────────────────────────────
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
  'Starts a new workflow instance. Templates are module-agnostic (mig 118). '
  'Removal Rule 1 (mig 163): step-1 approver = submitter → silently removed, no task. '
  'Removal Rule 2 (mig 163): remove_duplicate_approver=true AND step 2 has same '
  'approver → step 1 silently removed, no task (look-ahead keep-last). '
  'CC first steps auto-completed (mig 122). '
  'Visible skip (status=skipped) added in mig 164.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname FROM pg_proc
WHERE  proname IN ('wf_advance_instance', 'wf_submit')
ORDER  BY proname;

SELECT column_name, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'workflow_templates'
  AND  column_name  = 'remove_duplicate_approver';

-- =============================================================================
-- END OF MIGRATION 163
-- =============================================================================
