-- =============================================================================
-- Migration 120: Fix wf_submit — pass instance_id to wf_resolve_approver
--
-- BUG
-- ───
-- Migration 118 re-created wf_submit but carried over an outdated call:
--   wf_resolve_approver(v_first_step.id, auth.uid())
--
-- The function signature changed in migration 039 from (step_id, submitted_by)
-- to (step_id, instance_id). Passing auth.uid() (a profile UUID) caused:
--   "wf_resolve_approver: instance <uid> not found"
--
-- FIX
-- ───
-- Pass v_instance_id (the instance just inserted) as the second argument.
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
  v_approver_id uuid;
BEGIN
  -- ── Validate template ─────────────────────────────────────────────────────
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
  -- FIX: pass v_instance_id (not auth.uid()) — wf_resolve_approver(step_id, instance_id)
  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  -- ── Create task for step 1 ────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, status)
  VALUES
    (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, 'pending');

  -- ── Notify approver ───────────────────────────────────────────────────────
  PERFORM wf_notify(
    p_instance_id => v_instance_id,
    p_event       => 'submitted',
    p_step_id     => v_first_step.id,
    p_recipient   => v_approver_id
  );

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Submits a new workflow instance for a record. '
  'Templates are module-agnostic (module_code check removed in migration 118). '
  'Passes v_instance_id to wf_resolve_approver — fixed in migration 120.';

-- Verification
SELECT proname FROM pg_proc WHERE proname = 'wf_submit';
