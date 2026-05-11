-- =============================================================================
-- Migration 121: Correct wf_submit — complete rewrite
--
-- FIXES ALL ISSUES FROM MIGRATIONS 118 AND 120
-- ─────────────────────────────────────────────
-- 1. module_code mismatch guard REMOVED (from 118) — templates are module-agnostic
-- 2. wf_resolve_approver called with v_instance_id, not auth.uid() (from 120)
-- 3. wf_notify → wf_queue_notification (118 and 120 used non-existent wf_notify)
-- 4. Restored: v_due_at SLA deadline calculation (dropped in 118/120)
-- 5. Restored: RETURNING id INTO v_task_id on workflow_tasks insert (dropped in 118/120)
-- 6. Restored: workflow_action_log audit entry (dropped in 118/120)
-- 7. Restored: wf_sync_module_status call (dropped in 118/120)
-- 8. Restored: NULL approver guard with RAISE EXCEPTION (dropped in 118/120)
-- =============================================================================

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
  -- ── Validate template (module_code check REMOVED — templates are module-agnostic) ──
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
  -- Pass v_instance_id (not auth.uid()) — wf_resolve_approver(step_id, instance_id)
  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_submit: cannot resolve approver for step 1 of template %',
                    p_template_code;
  END IF;

  -- ── SLA deadline ──────────────────────────────────────────────────────────
  v_due_at := CASE
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

  -- ── Sync module status to 'submitted' ─────────────────────────────────────
  PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Starts a new workflow instance. Templates are module-agnostic (module_code check '
  'removed in migration 118, corrected in 121). Resolves approver via instance_id, '
  'creates task with SLA deadline, writes audit log, queues notification, syncs status.';

-- Verification
SELECT proname FROM pg_proc WHERE proname = 'wf_submit';
