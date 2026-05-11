-- =============================================================================
-- Migration 181: Allow wf_resubmit to update workflow_pending_changes.proposed_data
--
-- When an employee edits a profile section after a send-back (Update flow),
-- they change field values that live in workflow_pending_changes.proposed_data.
-- Previously wf_resubmit only resumed the workflow instance — it had no way
-- to persist the updated proposed data.
--
-- This migration adds an optional p_proposed_data parameter to wf_resubmit.
-- When provided, it:
--   1. Overwrites workflow_pending_changes.proposed_data for this instance
--   2. Resets workflow_pending_changes.status back to 'pending'
--   3. Proceeds with the normal resubmit logic (resume instance, new task, notify)
--
-- This makes the Update & Resubmit path complete for profile_* modules:
--   wf_prepare_update  → sets wpc.status = 'needs_update' (mig 180)
--   [employee edits]   → form fields updated in the UI
--   wf_resubmit(...)   → wpc.proposed_data updated + wpc.status = 'pending' (this mig)
--                       → workflow_instances.status = 'in_progress'
--
-- For expense_reports (no workflow_pending_changes row), p_proposed_data is
-- passed as NULL and the UPDATE is skipped — fully backward-compatible.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- Patch wf_resubmit: add p_proposed_data parameter
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id   uuid,
  p_response      text    DEFAULT NULL,
  p_proposed_data jsonb   DEFAULT NULL   -- NEW (mig 181): optional proposed_data update
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
  SELECT id, submitted_by, status, current_step, template_id,
         module_code, record_id, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: instance % not found', p_instance_id;
  END IF;

  -- Double-submit guard (mig 180): if already back in_progress, no-op
  IF v_instance.status = 'in_progress' THEN
    RETURN;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION 'wf_resubmit: instance is not awaiting clarification (status: %)',
                    v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_resubmit: only the original submitter can resubmit';
  END IF;

  -- ── Update proposed data if provided (mig 181) ────────────────────────────
  -- Only applies to profile_* modules (expense_reports has no wpc row).
  -- Resets status back to 'pending' so the approver sees it as an active request.
  IF p_proposed_data IS NOT NULL THEN
    UPDATE workflow_pending_changes
    SET    proposed_data = p_proposed_data,
           status        = 'pending',
           updated_at    = now()
    WHERE  instance_id = p_instance_id
      AND  status IN ('pending', 'needs_update');
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

  -- ── Re-lock module record (Gap 2 fix, mig 180) ────────────────────────────
  -- wf_sync_module_status maps 'submitted' → 'submitted' (expense_reports)
  -- and 'submitted' → 'pending' (profile_*).
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'submitted'
  );

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
      'response',   COALESCE(p_response, ''),
      'step_name',  v_step.name
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_resubmit(uuid, text, jsonb) IS
  'Submitter responds to a clarification request and resumes the workflow. '
  'Instance status returns to in_progress. Module record is re-locked to '
  'submitted/pending via wf_sync_module_status (Gap 2 fix, mig 180). '
  'Double-submit safe: no-op if instance already in_progress. '
  'p_proposed_data (mig 181): if provided, updates workflow_pending_changes '
  'proposed_data and resets status to pending before resuming. '
  'A new pending task is created for the approver at the current step '
  '(delegation rules re-applied). Approver receives a notification.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm wf_resubmit accepts the new parameter
SELECT proname, pronargs, proargnames
FROM   pg_proc
WHERE  proname = 'wf_resubmit';

-- =============================================================================
-- END OF MIGRATION 181
-- =============================================================================
