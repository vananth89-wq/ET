-- =============================================================================
-- Migration 210: Legacy ROLE fan-out in wf_return_to_previous_step
--
-- PROBLEM
-- ───────
-- wf_return_to_previous_step resolves the previous step's approver via
-- wf_resolve_approver() which uses LIMIT 1. For a legacy ROLE step (Finance,
-- etc. with approval_mode IS NULL), only the first matching role holder gets
-- the task back. The second holder is skipped entirely.
--
-- Mig 208 fixed wf_force_advance.
-- Mig 209 fixed wf_advance_instance + wf_submit.
-- This migration fixes wf_return_to_previous_step.
--
-- ROOT CAUSE
-- ──────────
-- The function was written before multi-approver support. It calls
-- wf_resolve_approver() which still uses LIMIT 1 for the legacy path.
-- The Finance template (approver_type=ROLE, approval_mode IS NULL, no rows
-- in workflow_step_approvers) falls through to this legacy single-task path.
--
-- FIX
-- ───
-- Replace the single wf_resolve_approver() call + single INSERT with three
-- paths — the same pattern used in mig 208 / 209:
--
--   approval_mode IS NOT NULL          → Path A: existing behaviour (unchanged)
--   approval_mode IS NULL, type=ROLE   → Path B: NEW — fan out to all active
--                                         role holders (delegation per-holder,
--                                         submitter skipped per-holder)
--   approval_mode IS NULL, other type  → Path C: existing single-approver
--                                         behaviour (unchanged)
--
-- Zero-task handling (Path B):
--   RAISE EXCEPTION — returning to a step with no eligible approver is an
--   error (same as wf_force_advance mig 208). Full transaction rollback undoes
--   the task-returned mark and the instance current_step rollback.
--
-- Audit log:
--   task_id FK still points to v_first_task_id for backward compat.
--   metadata gains a task_ids uuid[] for full traceability when fan-out
--   creates multiple tasks.
--   Notification is queued for each role holder individually.
--
-- SAFETY ANALYSIS
-- ───────────────
-- Functions NOT changed (all already verified safe in mig 209 comment):
--   wf_approve, wf_reject, wf_return_to_initiator, wf_admin_decline,
--   wf_reassign, wf_force_advance, wf_advance_instance, wf_submit ✓
--
-- REMAINING GAP (out of scope for this migration)
-- ────────────────────────────────────────────────
-- wf_resubmit also calls wf_resolve_approver() for the current step.
-- If the step is a legacy ROLE step, only one holder gets the task after
-- the submitter responds. This is a lower-priority fix (resubmit is used
-- far less frequently than return_to_previous_step).
--
-- NO SCHEMA CHANGES — pure function replacement.
-- =============================================================================


CREATE OR REPLACE FUNCTION wf_return_to_previous_step(
  p_task_id uuid,
  p_reason  text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task           RECORD;
  v_instance       RECORD;
  v_prev_step      RECORD;
  -- Single-approver path variables (paths A + C)
  v_approver_id    uuid;
  v_due_at         timestamptz;
  v_new_task_id    uuid;
  -- Legacy ROLE fan-out variables (path B)
  v_role_holder_id uuid;
  v_delegate_id    uuid;
  v_tasks_created  integer := 0;
  v_first_task_id  uuid;
  v_all_task_ids   uuid[] := '{}';
BEGIN
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

  -- ── Find the previous active step ─────────────────────────────────────────
  -- Prefer the most-recently approved step from the action log (handles skipped
  -- steps correctly). Fall back to highest step_order < current if no log entry.
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

  -- ── Create task(s) for the previous step — three paths ────────────────────

  IF v_prev_step.approval_mode IS NOT NULL THEN
    -- ── Path A: new multi-approver schema (approval_mode IS NOT NULL) ─────────
    -- Existing behaviour — single task via wf_resolve_approver.
    -- Note: for all_must_approve mode this is also incomplete (same LIMIT 1 gap)
    -- but fixing that is out of scope here; it predates this migration.
    v_approver_id := wf_resolve_approver(v_prev_step.id, v_task.instance_id);

    IF v_approver_id IS NULL THEN
      RAISE EXCEPTION 'wf_return_to_previous_step: could not resolve approver for step %',
                      v_prev_step.step_order;
    END IF;

    INSERT INTO workflow_tasks
      (instance_id, step_id, step_order, assigned_to, due_at)
    VALUES
      (v_task.instance_id, v_prev_step.id, v_prev_step.step_order, v_approver_id, v_due_at)
    RETURNING id INTO v_new_task_id;

    v_first_task_id := v_new_task_id;
    v_all_task_ids  := ARRAY[v_new_task_id];

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

  ELSIF v_prev_step.approver_type = 'ROLE' AND v_prev_step.approver_role IS NOT NULL THEN
    -- ── Path B: legacy ROLE step (approval_mode IS NULL, type = ROLE) ─────────
    -- Fan out: one task per active role holder. Delegation applied per-holder.
    -- Submitter skipped per-holder (same rules as wf_advance_instance / wf_force_advance).
    FOR v_role_holder_id IN
      SELECT ur.profile_id
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      WHERE  r.code    = v_prev_step.approver_role
        AND  r.active  = true
        AND  ur.is_active = true
        AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
    LOOP
      -- Skip the submitter at the holder level (before delegation lookup)
      CONTINUE WHEN v_role_holder_id = v_instance.submitted_by;

      -- Resolve any active delegation for this holder
      SELECT d.delegate_id
      INTO   v_delegate_id
      FROM   workflow_delegations d
      WHERE  d.delegator_id = v_role_holder_id
        AND  d.is_active    = true
        AND  (d.expires_at IS NULL OR d.expires_at > now())
      LIMIT  1;

      v_approver_id := COALESCE(v_delegate_id, v_role_holder_id);

      -- Also skip if the resolved approver (after delegation) is the submitter
      CONTINUE WHEN v_approver_id = v_instance.submitted_by;

      INSERT INTO workflow_tasks
        (instance_id, step_id, step_order, assigned_to, due_at)
      VALUES
        (v_task.instance_id, v_prev_step.id, v_prev_step.step_order, v_approver_id, v_due_at)
      RETURNING id INTO v_new_task_id;

      v_tasks_created := v_tasks_created + 1;
      v_all_task_ids  := array_append(v_all_task_ids, v_new_task_id);

      IF v_first_task_id IS NULL THEN
        v_first_task_id := v_new_task_id;
      END IF;

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
    END LOOP;

    -- Zero tasks = no eligible approver exists for the role; roll back everything.
    IF v_tasks_created = 0 THEN
      RAISE EXCEPTION
        'wf_return_to_previous_step: no eligible approver found for role "%" at step %',
        v_prev_step.approver_role, v_prev_step.step_order;
    END IF;

  ELSE
    -- ── Path C: legacy single-approver (approval_mode IS NULL, type ≠ ROLE) ───
    -- Original behaviour — unchanged.
    v_approver_id := wf_resolve_approver(v_prev_step.id, v_task.instance_id);

    IF v_approver_id IS NULL THEN
      RAISE EXCEPTION 'wf_return_to_previous_step: could not resolve approver for step %',
                      v_prev_step.step_order;
    END IF;

    INSERT INTO workflow_tasks
      (instance_id, step_id, step_order, assigned_to, due_at)
    VALUES
      (v_task.instance_id, v_prev_step.id, v_prev_step.step_order, v_approver_id, v_due_at)
    RETURNING id INTO v_new_task_id;

    v_first_task_id := v_new_task_id;
    v_all_task_ids  := ARRAY[v_new_task_id];

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

  END IF;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  -- Logged against the original task (p_task_id) — the task that was returned.
  -- v_first_task_id used as FK for backward compat; v_all_task_ids in metadata
  -- captures all tasks created (useful when fan-out creates more than one).
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    v_task.instance_id,
    p_task_id,
    auth.uid(),
    'returned_to_previous_step',
    v_task.step_order,
    COALESCE(p_reason, 'Returned to previous step for re-review.'),
    jsonb_build_object(
      'from_step',   v_task.step_order,
      'to_step',     v_prev_step.step_order,
      'new_task_id', v_first_task_id,    -- backward compat
      'task_ids',    v_all_task_ids       -- full fan-out list
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_return_to_previous_step(uuid, text) IS
  'Returns a workflow to the previous approval step. '
  'For legacy ROLE steps (approval_mode IS NULL), all active role holders '
  'receive a new pending task (fan-out). Delegation applied per-holder; '
  'submitter skipped per-holder. For all other steps, the original single-task '
  'behaviour is preserved. RAISE EXCEPTION if no eligible approver is found.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname, pronargs
FROM   pg_proc
WHERE  proname = 'wf_return_to_previous_step';
