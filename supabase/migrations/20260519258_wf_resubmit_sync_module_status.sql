-- Migration 258: wf_resubmit — call wf_sync_module_status to re-lock module record
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM (Gap 15)
-- After an approver sends a hire record back for clarification, wf_return_to_initiator
-- calls wf_sync_module_status('awaiting_clarification') which unlocks the record
-- (Pending+locked → Incomplete+unlocked) so HR can edit it. When HR fixes the record
-- and calls wf_resubmit, the workflow instance is correctly reset to in_progress at
-- Step 1 — but wf_sync_module_status is NEVER called. The employee record stays
-- Incomplete+locked=false, meaning HR can still edit the form while it is supposedly
-- under review again.
--
-- Mig 224 added the 'submitted' branch to wf_sync_module_status specifically for
-- this purpose (comment: "called by wf_resubmit — re-locks on resubmit") but the
-- call was never added to wf_resubmit itself.
--
-- SOLUTION
-- Add record_id to the v_instance SELECT, then call
--   wf_sync_module_status(module_code, record_id, 'submitted')
-- immediately after the instance is reset to in_progress. For employee_hire this
-- flips the record back to Pending+locked=true. For other modules the call is a
-- no-op (RAISE NOTICE) until they add a 'submitted' handler.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id   uuid,
  p_response      text  DEFAULT NULL,
  p_proposed_data jsonb DEFAULT NULL   -- accepted for forward-compat; not used yet
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
    RAISE EXCEPTION 'wf_resubmit: only the original submitter can resubmit';
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
  -- For employee_hire: flips record back to Pending+locked=true so HR cannot
  -- edit while the resubmitted request is under review again.
  -- For other modules without a 'submitted' handler this is a no-op.
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

COMMENT ON FUNCTION wf_resubmit(uuid, text, jsonb) IS
  'Submitter responds to a clarification request and resubmits from Step 1. '
  'Full approval chain runs again — all approvers re-review the updated request. '
  'Instance status returns to in_progress with current_step = 1. '
  'Mig 258: now calls wf_sync_module_status(..submitted) to re-lock the module '
  'record (employee_hire → Pending+locked=true; other modules → no-op until they '
  'add a submitted handler). p_proposed_data accepted for forward-compat, not used.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE  proname = 'wf_resubmit'
      AND  pronargs = 3
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_resubmit(uuid, text, jsonb) not found after migration.';
  END IF;
  RAISE NOTICE 'Migration 258 verified: wf_resubmit present with 3 params.';
END;
$$;
