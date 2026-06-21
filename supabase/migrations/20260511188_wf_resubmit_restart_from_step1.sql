-- =============================================================================
-- wf_resubmit — restart workflow from Step 1 on resubmission
--
-- Previous behaviour: resubmit re-assigned to the SAME step that requested
-- clarification (e.g. Finance at Step 2), bypassing earlier approvers.
--
-- New behaviour: resubmit resets current_step = 1 and creates a new pending
-- task for Step 1's approver, so the full approval chain runs again.
-- This mirrors what happens on the original submission.
-- =============================================================================

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
  v_step1        RECORD;
  v_approver_id  uuid;
  v_due_at       timestamptz;
  v_new_task_id  uuid;
BEGIN
  -- ── Load and lock instance ─────────────────────────────────────────────────
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

  -- ── Always restart from Step 1 ─────────────────────────────────────────────
  -- Resubmission means the submitter has updated / clarified their request.
  -- All approvers should review again from the beginning, just like the
  -- original submission. We do NOT resume at the step that requested
  -- clarification, because earlier approvers may also want to re-review.
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

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id, v_new_task_id, auth.uid(),
    'resubmitted',
    1,
    COALESCE(p_response, 'Submitter resubmitted after clarification.')
  );

  -- ── Notify Step 1 approver ─────────────────────────────────────────────────
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

COMMENT ON FUNCTION wf_resubmit(uuid, text) IS
  'Submitter responds to a clarification request and resubmits from Step 1. '
  'The full approval chain runs again — all approvers re-review the updated request. '
  'Instance status returns to in_progress with current_step = 1.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname, prosrc LIKE '%current_step = 1%' AS resets_to_step1
FROM   pg_proc
WHERE  proname = 'wf_resubmit';
