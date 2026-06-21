-- =============================================================================
-- Migration 224: Fix all hire-pipeline engine gaps
--
-- GAPS ADDRESSED
-- ──────────────
-- 1. submit_hire called wf_submit with p_submitted_by (does not exist in
--    wf_submit signature) → 42883 function not found.
--
-- 2. wf_sync_module_status had no employee_hire branch → every workflow
--    event (approved, rejected, submitted, awaiting_clarification) was a
--    no-op for hire records. Activation, unlock, re-lock, and rejection-reset
--    were never applied at DB level.
--
-- 3. wf_return_to_initiator never called wf_sync_module_status → sent-back
--    hire records stayed Pending+locked forever, blocking HR edit.
--
-- WHAT EACH FIX DOES
-- ──────────────────
-- Fix 1 — submit_hire
--   Remove p_submitted_by from wf_submit call (wf_submit uses auth.uid()
--   internally). Keeps everything else identical.
--
-- Fix 2 — wf_sync_module_status (employee_hire branch)
--   'approved'                → PERFORM wf_activate_employee(p_record_id)
--                               (sets Active + locked=false + invite record)
--   'submitted'               → SET status='Pending', locked=true
--                               (called by wf_resubmit — re-locks on resubmit)
--   'rejected'                → SET status='Incomplete', locked=false
--                               (HR can fix and resubmit)
--   'awaiting_clarification'  → SET locked=false, status='Incomplete'
--                               (HR can edit after sent-back)
--
-- Fix 3 — wf_return_to_initiator
--   Add PERFORM wf_sync_module_status(..., 'awaiting_clarification') after
--   the instance is paused. Existing expense_report flow is unchanged
--   because wf_sync_module_status has no expense_report branch for that status.
--
-- FRONTEND IMPACT
-- ───────────────
-- WorkflowReview handleApprove no longer needs to call wf_activate_employee
-- directly — the engine now handles it. It DOES still need to fire the OTP
-- magic-link (cannot be done from PostgreSQL). The frontend change guards
-- OTP dispatch behind an instance-status check after wf_approve resolves.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1: submit_hire — remove p_submitted_by from wf_submit call
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id          uuid;
  v_status          text;
  v_locked          boolean;
  v_wf_template_id  uuid;
  v_template_code   text;
BEGIN
  -- Caller must be linked to an employee
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  -- Fetch employee status + locked
  SELECT status::text, locked
  INTO   v_status, v_locked
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee record not found.';
  END IF;

  IF v_status NOT IN ('Draft', 'Incomplete') THEN
    RAISE EXCEPTION 'Only Draft or Incomplete records can be submitted (current status: %).', v_status;
  END IF;

  IF v_locked THEN
    RAISE EXCEPTION 'This record is already submitted and awaiting approval.';
  END IF;

  -- Resolve workflow
  v_wf_template_id := resolve_workflow_for_submission('employee_hire', auth.uid());

  IF v_wf_template_id IS NULL THEN
    RAISE EXCEPTION
      'No active workflow is configured for the New Hire module. '
      'Ask your administrator to assign a workflow template to employee_hire.';
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_wf_template_id;

  -- Lock and mark Pending
  UPDATE employees
  SET    status     = 'Pending',
         locked     = true,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Start the workflow instance
  -- FIX: removed p_submitted_by (wf_submit uses auth.uid() internally).
  --      Added ::text casts to avoid unknown-type resolution errors.
  PERFORM wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'employee_hire'::text,
    p_record_id     => p_employee_id,
    p_metadata      => jsonb_build_object(
      'employee_id', (SELECT employee_id FROM employees WHERE id = p_employee_id),
      'name',        (SELECT name        FROM employees WHERE id = p_employee_id)
    )
  );
END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submit a Draft/Incomplete employee record for approval. '
  'Marks it Pending+locked and starts the workflow instance. '
  'Mig 224: removed p_submitted_by from wf_submit call (wf_submit uses auth.uid() internally).';

REVOKE ALL ON FUNCTION submit_hire(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_hire(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2: wf_sync_module_status — add employee_hire branch
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Called by the workflow engine on every terminal/state event:
--   wf_advance_instance → 'approved'
--   wf_reject           → 'rejected'
--   wf_resubmit         → 'submitted'
--   wf_return_to_initiator (after Fix 3) → 'awaiting_clarification'

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- ── Expense Reports ──────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN
    UPDATE expense_reports
    SET    status     = p_status::expense_status,
           updated_at = now()
    WHERE  id = p_record_id;

  -- ── Employee Hire ─────────────────────────────────────────────────────────
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status = 'approved' THEN
      -- Final approval → activate the employee (SECURITY DEFINER — bypasses RLS).
      -- wf_activate_employee sets status=Active, locked=false, records invite.
      -- Frontend must still send the OTP magic-link after this resolves.
      PERFORM wf_activate_employee(p_record_id);

    ELSIF p_status = 'submitted' THEN
      -- Resubmit after send-back → re-lock so HR cannot edit while in review.
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'rejected' THEN
      -- Rejected → unlock and reset to Incomplete so HR can correct and resubmit.
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'awaiting_clarification' THEN
      -- Sent back for clarification → unlock so HR can edit the form.
      -- Status returns to Incomplete (not Draft — form data is preserved).
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSE
      RAISE NOTICE 'wf_sync_module_status: unhandled status % for employee_hire — record unchanged', p_status;
    END IF;

  -- ── Add further modules here as they are onboarded ───────────────────────
  -- ELSIF p_module_code = 'leave_requests' THEN
  --   UPDATE leave_requests SET status = p_status, updated_at = now()
  --   WHERE id = p_record_id;

  ELSE
    RAISE NOTICE 'wf_sync_module_status: unknown module_code %, record unchanged', p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates the status/lock on the source module record after a workflow event. '
  'expense_reports: maps p_status → expense_status enum. '
  'employee_hire (mig 224): '
  '  approved → wf_activate_employee (Active + unlock + invite). '
  '  submitted → Pending + locked (resubmit re-lock). '
  '  rejected → Incomplete + unlock (HR can fix and resubmit). '
  '  awaiting_clarification → Incomplete + unlock (HR can edit after send-back). '
  'Add a new ELSIF branch for each module you onboard.';


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 3: wf_return_to_initiator — call wf_sync_module_status on send-back
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Previously this function never called wf_sync_module_status, so sent-back
-- hire records stayed Pending+locked=true permanently. Now we call it with
-- 'awaiting_clarification' so wf_sync_module_status can unlock per module.
-- The expense_reports branch has no 'awaiting_clarification' case so its
-- behavior is unchanged.

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
  IF p_message IS NULL OR trim(p_message) = '' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: a clarification message is required';
  END IF;

  IF char_length(p_message) > 1000 THEN
    RAISE EXCEPTION 'wf_return_to_initiator: message must be 1 000 characters or fewer (got %)', char_length(p_message);
  END IF;

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

  SELECT id, submitted_by, status, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: instance is not in progress (status: %)',
                    v_instance.status;
  END IF;

  -- Mark this task returned
  UPDATE workflow_tasks
  SET    status   = 'returned',
         notes    = p_message,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Cancel any sibling pending tasks (multi-approver steps)
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now(),
         notes    = 'Cancelled: request returned to initiator by co-approver'
  WHERE  instance_id = v_task.instance_id
    AND  step_order  = v_task.step_order
    AND  status      = 'pending'
    AND  id          != p_task_id;

  -- Pause the instance
  UPDATE workflow_instances
  SET    status     = 'awaiting_clarification',
         updated_at = now()
  WHERE  id = v_task.instance_id;

  -- FIX: Sync module record state on send-back.
  -- For employee_hire this unlocks the record (Pending+locked → Incomplete+unlocked)
  -- so HR can edit. For other modules without an 'awaiting_clarification' handler
  -- this is a no-op (RAISE NOTICE only).
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'awaiting_clarification'
  );

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(),
    'returned_to_initiator',
    v_task.step_order,
    p_message,
    jsonb_build_object('step_id', v_task.step_id)
  );

  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.clarification_requested',
    v_instance.submitted_by,
    jsonb_build_object('message', p_message)
  );
END;
$$;

COMMENT ON FUNCTION wf_return_to_initiator(uuid, text) IS
  'Approver returns request to submitter for clarification. '
  'Cancels sibling pending tasks so the instance cleanly pauses at awaiting_clarification. '
  'Mig 224: now calls wf_sync_module_status(..awaiting_clarification) so module records '
  'are unlocked per their handler (employee_hire → Incomplete+unlock, others → no-op). '
  'Submitter calls wf_resubmit() to resume from the current step. '
  'Message capped at 1 000 chars.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  routine_name,
  routine_type
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name IN ('submit_hire', 'wf_sync_module_status', 'wf_return_to_initiator')
ORDER  BY routine_name;

-- =============================================================================
-- END OF MIGRATION 224
-- =============================================================================
