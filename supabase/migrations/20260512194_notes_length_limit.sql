-- =============================================================================
-- Migration 194: Enforce 1 000-character limit on workflow notes
--
-- PURPOSE
-- ───────
-- The decision note textarea previously had no length cap. This migration
-- closes the gap at the database layer to match the 1 000-char frontend limit.
--
-- CHANGES
-- ───────
-- 1. ADD CHECK constraints (NOT VALID) on:
--      workflow_tasks.notes
--      workflow_action_log.notes
--      line_items.note               ← submitter-side (expense line item)
--    NOT VALID skips a full table scan — the constraint applies to new /
--    updated rows only, which is the safety property we need.
--
-- 2. Add a char_length guard at the top of each note-bearing RPC:
--      wf_approve              (p_notes   — optional)
--      wf_reject               (p_reason  — required)
--      wf_return_to_initiator  (p_message — required)
--      wf_return_to_previous_step (p_reason — optional)
--    Full function bodies are reproduced from their most-recent definitions
--    (mig 056 for approve/reject, mig 048 for return functions) — only the
--    length guard block is new.
--
-- NOTE: wf_bulk_approve delegates to wf_approve, so it inherits the guard.
-- =============================================================================

-- ── 1. Column-level CHECK constraints ────────────────────────────────────────

ALTER TABLE workflow_tasks
  ADD CONSTRAINT wt_notes_max_length
  CHECK (notes IS NULL OR char_length(notes) <= 1000)
  NOT VALID;

ALTER TABLE workflow_action_log
  ADD CONSTRAINT wal_notes_max_length
  CHECK (notes IS NULL OR char_length(notes) <= 1000)
  NOT VALID;

-- Submitter-side: line item notes (expense form)
ALTER TABLE line_items
  ADD CONSTRAINT li_note_max_length
  CHECK (note IS NULL OR char_length(note) <= 1000)
  NOT VALID;


-- ── 2. wf_approve ─────────────────────────────────────────────────────────────
--    Source: migration 056 + length guard

CREATE OR REPLACE FUNCTION wf_approve(
  p_task_id uuid,
  p_notes   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  -- ── Guard: note length ────────────────────────────────────────────────────
  IF char_length(p_notes) > 1000 THEN
    RAISE EXCEPTION 'wf_approve: note must be 1 000 characters or fewer (got %)', char_length(p_notes);
  END IF;

  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_approve: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_approve: task is not pending (current status: %)', v_task.status;
  END IF;

  -- Allow assigned approver OR any admin/workflow.admin to approve
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_approve: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_approve: workflow instance is not active (status: %)', v_instance.status;
  END IF;

  -- Mark task approved
  UPDATE workflow_tasks
  SET    status   = 'approved',
         notes    = p_notes,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Audit log
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'approved', v_task.step_order, p_notes);

  -- Advance instance
  PERFORM wf_advance_instance(v_task.instance_id);
END;
$$;

COMMENT ON FUNCTION wf_approve(uuid, text) IS
  'Approves a pending workflow task. Callable by the assigned approver or any '
  'user with admin role / workflow.admin permission. Note capped at 1 000 chars (mig 194).';


-- ── 3. wf_reject ──────────────────────────────────────────────────────────────
--    Source: migration 056 + length guard

CREATE OR REPLACE FUNCTION wf_reject(
  p_task_id uuid,
  p_reason  text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_reject: a rejection reason is required';
  END IF;

  -- ── Guard: note length ────────────────────────────────────────────────────
  IF char_length(p_reason) > 1000 THEN
    RAISE EXCEPTION 'wf_reject: reason must be 1 000 characters or fewer (got %)', char_length(p_reason);
  END IF;

  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reject: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_reject: task is not pending (current status: %)', v_task.status;
  END IF;

  -- Allow assigned approver OR any admin/workflow.admin to reject
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_reject: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, submitted_by, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_reject: workflow instance is not active (status: %)', v_instance.status;
  END IF;

  -- Mark task rejected
  UPDATE workflow_tasks
  SET    status   = 'rejected',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Cancel all other pending tasks on this instance
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = v_task.instance_id
    AND  status      = 'pending'
    AND  id          != p_task_id;

  -- Mark instance rejected
  UPDATE workflow_instances
  SET    status       = 'rejected',
         completed_at = now(),
         updated_at   = now()
  WHERE  id = v_task.instance_id;

  -- Sync module record status
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'rejected');

  -- Audit log
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'rejected', v_task.step_order, p_reason);

  -- Notify submitter
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.rejected',
    v_instance.submitted_by,
    jsonb_build_object('reason', p_reason, 'step_order', v_task.step_order)
  );
END;
$$;

COMMENT ON FUNCTION wf_reject(uuid, text) IS
  'Rejects a pending workflow task, cancels the instance, and notifies the submitter. '
  'Callable by the assigned approver or any user with admin role / workflow.admin permission. '
  'Reason capped at 1 000 chars (mig 194).';


-- ── 4. wf_return_to_initiator ─────────────────────────────────────────────────
--    Source: migration 048 + length guard

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

  -- ── Guard: note length ────────────────────────────────────────────────────
  IF char_length(p_message) > 1000 THEN
    RAISE EXCEPTION 'wf_return_to_initiator: message must be 1 000 characters or fewer (got %)', char_length(p_message);
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
  'wf_resubmit() to resume the workflow from the same step. '
  'Message capped at 1 000 chars (mig 194).';


-- ── 5. wf_return_to_previous_step ────────────────────────────────────────────
--    Source: migration 048 + length guard

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
  -- ── Guard: note length ────────────────────────────────────────────────────
  IF char_length(p_reason) > 1000 THEN
    RAISE EXCEPTION 'wf_return_to_previous_step: reason must be 1 000 characters or fewer (got %)', char_length(p_reason);
  END IF;

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
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes,
     metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(),
    'returned_to_previous_step',
    v_task.step_order,
    COALESCE(p_reason, 'Returned to previous step for re-review.'),
    jsonb_build_object(
      'from_step',    v_task.step_order,
      'to_step',      v_prev_step.step_order,
      'new_task_id',  v_new_task_id
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
  'most-recently approved step (handles skipped steps correctly). '
  'Reason capped at 1 000 chars (mig 194).';


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Constraints exist
SELECT conname, pg_get_constraintdef(oid) AS def
FROM   pg_constraint
WHERE  conname IN ('wt_notes_max_length', 'wal_notes_max_length', 'li_note_max_length');

-- 2. All four RPCs have the length guard
SELECT proname,
       prosrc LIKE '%1000%' AS has_length_guard
FROM   pg_proc
WHERE  proname IN (
         'wf_approve',
         'wf_reject',
         'wf_return_to_initiator',
         'wf_return_to_previous_step'
       )
ORDER BY proname;

-- =============================================================================
-- END OF MIGRATION 194
--
-- After applying:
--   npx supabase db push
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
--   (No new public types — constraint + function body changes only.)
-- =============================================================================
