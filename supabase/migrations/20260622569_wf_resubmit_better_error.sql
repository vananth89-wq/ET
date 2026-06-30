-- Migration 569 — Improve wf_resubmit error message for non-submitter
-- ────────────────────────────────────────────────────────────────────
-- Only change: the submitter guard now resolves the original submitter's
-- name and includes it in the exception message, so the user knows exactly
-- who needs to resubmit instead of seeing a terse internal error.

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id   uuid,
  p_response      text  DEFAULT NULL,
  p_proposed_data jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance        RECORD;
  v_step1           RECORD;
  v_approver_id     uuid;
  v_due_at          timestamptz;
  v_new_task_id     uuid;
  v_submitter_name  text;
BEGIN
  -- ── Load and lock instance ─────────────────────────────────────────────────
  SELECT id, submitted_by, status, current_step, template_id, module_code,
         record_id, metadata
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
    SELECT COALESCE(e.name, au.email, 'another user')
    INTO   v_submitter_name
    FROM   profiles p
    LEFT JOIN employees  e  ON e.id  = p.employee_id
    LEFT JOIN auth.users au ON au.id = p.id
    WHERE  p.id = v_instance.submitted_by;

    RAISE EXCEPTION
      'This record was submitted for approval by %. Only that person (or an admin) can resubmit it after it has been sent back for corrections.',
      COALESCE(v_submitter_name, 'another user')
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Always restart from Step 1 ─────────────────────────────────────────────
  SELECT ws.id, ws.step_order, ws.name, ws.sla_hours
  INTO   v_step1
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  = 1
    AND  ws.is_active   = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: step 1 not found for template %',
                    v_instance.template_id;
  END IF;

  -- ── Resolve Step 1 approver (delegation rules re-applied) ─────────────────
  v_approver_id := wf_resolve_approver(v_step1.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_resubmit: could not resolve an approver for step 1';
  END IF;

  -- ── Cancel any stray pending tasks (defensive — should be none) ───────────
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- ── Reset instance to Step 1 and resume ───────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'in_progress',
         current_step = 1,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Re-lock the module record ──────────────────────────────────────────────
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'submitted'
  );

  -- ── Compute SLA deadline for Step 1 ───────────────────────────────────────
  v_due_at := CASE
    WHEN v_step1.sla_hours IS NOT NULL
    THEN now() + (v_step1.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create new pending task at Step 1 ─────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_step1.id, v_step1.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id, v_new_task_id, auth.uid(),
    'resubmitted',
    1,
    COALESCE(p_response, 'Submitter resubmitted after clarification.')
  );

  -- ── Notify Step 1 approver ────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.clarification_submitted',
    v_approver_id,
    jsonb_build_object(
      'response',  COALESCE(p_response, ''),
      'step_name', v_step1.name
    )
  );
END;
$$;

REVOKE ALL     ON FUNCTION wf_resubmit(uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_resubmit(uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION wf_resubmit(uuid, text, jsonb) IS
  'Submitter responds to a clarification request and resubmits from Step 1. '
  'Full approval chain runs again — all approvers re-review the updated request. '
  'Instance status returns to in_progress with current_step = 1. '
  'Mig 258: wf_sync_module_status re-locks the module record. '
  'Mig 569: submitter guard now names the original submitter in the error message.';
