-- =============================================================================
-- Migration 180: Update flow for Sent-Back requests
--
-- Adds the ability for an employee to edit their request data before
-- resubmitting, rather than only adding a comment.
--
-- Two changes:
--
-- PART 1 — Schema: add 'needs_update' status to both module tables
--   • expense_status enum   → ADD VALUE 'needs_update'
--   • workflow_pending_changes.status CHECK → ADD 'needs_update'
--   • wf_sync_module_status → handle 'needs_update' for profile_* modules
--     (expense_reports handles it automatically via enum cast)
--
-- PART 2 — New RPC wf_prepare_update(p_instance_id)
--   Sets the module record to 'needs_update' so the edit form can:
--     • unlock fields for editing
--     • prevent the normal Submit path (which would create a new instance)
--   Returns module_code + record_id so the frontend can navigate to the
--   correct edit route.
--
-- PART 3 — Patch wf_resubmit
--   After resuming the workflow instance to 'in_progress', re-locks the
--   module record back to 'submitted' (expense_reports) / 'pending'
--   (profile_*) by calling wf_sync_module_status.
--
--   This closes the dangling-draft gap (Gap 1): if the employee clicked
--   Update (module → needs_update) but then chose Respond & Resume instead
--   of updating, wf_resubmit re-locks automatically via both paths.
--
--   This also closes the re-lock gap (Gap 2): previously wf_resubmit left
--   the module status unchanged after resuming the instance.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Schema additions
-- ════════════════════════════════════════════════════════════════════════════

-- 1a. Add 'needs_update' to expense_status enum
--     Safe to run repeatedly (IF NOT EXISTS guard).
ALTER TYPE expense_status ADD VALUE IF NOT EXISTS 'needs_update' AFTER 'submitted';

-- 1b. Extend workflow_pending_changes.status to include 'needs_update'
ALTER TABLE workflow_pending_changes
  DROP CONSTRAINT IF EXISTS workflow_pending_changes_status_check;

ALTER TABLE workflow_pending_changes
  ADD CONSTRAINT workflow_pending_changes_status_check
  CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn', 'needs_update'));

-- 1c. Update wf_sync_module_status to map 'needs_update' for profile_* modules.
--     expense_reports: no CASE change needed — 'needs_update' is now a valid
--     enum value and is cast directly via p_status::expense_status.

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
BEGIN
  -- ── Expense reports ────────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles
      WHERE  id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  -- p_record_id = workflow_pending_changes.id
  --
  -- Status mapping (mig 173 + mig 180 addition):
  --   'submitted'    → 'pending'      (wf just started)
  --   'in_progress'  → 'pending'      (wf advancing)
  --   'needs_update' → 'needs_update' (employee editing after send-back, mig 180)
  --   'draft'        → 'withdrawn'    (wf_withdraw)
  --   'cancelled'    → 'withdrawn'    (admin cancel)
  --   'approved'     → 'approved'
  --   'rejected'     → 'rejected'
  --   'withdrawn'    → 'withdrawn'
  --   anything else  → no-op
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'    THEN 'pending'
          WHEN 'in_progress'  THEN 'pending'
          WHEN 'needs_update' THEN 'needs_update'   -- ← NEW (mig 180)
          WHEN 'draft'        THEN 'withdrawn'
          WHEN 'cancelled'    THEN 'withdrawn'
          WHEN 'approved'     THEN 'approved'
          WHEN 'rejected'     THEN 'rejected'
          WHEN 'withdrawn'    THEN 'withdrawn'
          ELSE status   -- no-op for unknown statuses
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Future modules ─────────────────────────────────────────────────────────
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates status on the source module record after a workflow event. '
  'expense_reports: sets status/approved_at/approved_by. '
  'profile_*: maps workflow engine statuses to wpc CHECK-constraint values '
  '(submitted/in_progress→pending, needs_update→needs_update, draft/cancelled→withdrawn, '
  'approved/rejected pass-through). '
  'Mig 070: approved_at/approved_by. Mig 161: profile_* branch. '
  'Mig 162: draft→withdrawn. Mig 173: submitted/in_progress→pending fix. '
  'Mig 180: needs_update pass-through.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — wf_prepare_update
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_prepare_update(
  p_instance_id uuid
) RETURNS TABLE(module_code text, record_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  -- ── Load and lock instance ─────────────────────────────────────────────────
  SELECT id, submitted_by, status, module_code, record_id, current_step
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_prepare_update: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION
      'wf_prepare_update: instance is not awaiting clarification (status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_prepare_update: only the submitter or an admin can initiate an update';
  END IF;

  -- ── Unlock module record for editing ──────────────────────────────────────
  -- Sets the module record to 'needs_update'.
  -- For expense_reports: expense_reports.status = 'needs_update' (enum value)
  -- For profile_*:      workflow_pending_changes.status = 'needs_update'
  --
  -- This status signals to the edit form:
  --   1. Fields are unlocked for editing
  --   2. Normal Submit (which creates a new workflow instance) is blocked
  --   3. Only "Update & Resubmit" (which calls wf_resubmit) is allowed
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'needs_update'
  );

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id,
    auth.uid(),
    'update_started',
    v_instance.current_step,
    'Submitter opened request for editing after clarification'
  );

  -- ── Return routing info to frontend ───────────────────────────────────────
  RETURN QUERY
    SELECT v_instance.module_code::text, v_instance.record_id;
END;
$$;

COMMENT ON FUNCTION wf_prepare_update(uuid) IS
  'Unlocks a sent-back module record for employee editing. '
  'Sets module status to needs_update (preventing normal new-instance Submit). '
  'Returns module_code and record_id so the frontend can navigate to the '
  'correct edit form with ?resume_instance={instanceId}. '
  'Only valid when instance is awaiting_clarification.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — Patch wf_resubmit: re-lock module after resuming
-- ════════════════════════════════════════════════════════════════════════════
--
-- Previously wf_resubmit resumed the workflow instance but left the module
-- record in whatever status it had (e.g. needs_update, or the original
-- submitted status). This patch adds the wf_sync_module_status call to
-- explicitly re-lock the module back to submitted/pending after the workflow
-- resumes. Both Respond & Resume and Update & Resubmit converge on this
-- function, so the re-lock is applied regardless of which button was used.

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
  v_step         RECORD;
  v_approver_id  uuid;
  v_due_at       timestamptz;
  v_new_task_id  uuid;
BEGIN
  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT id, submitted_by, status, current_step, template_id,
         module_code, record_id, metadata           -- record_id added (mig 180)
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
  -- Regardless of whether the employee updated data or just added a comment,
  -- the module must be locked back to its in-progress state.
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

COMMENT ON FUNCTION wf_resubmit(uuid, text) IS
  'Submitter responds to a clarification request and resumes the workflow. '
  'Instance status returns to in_progress. Module record is re-locked to '
  'submitted/pending via wf_sync_module_status (Gap 2 fix, mig 180). '
  'Double-submit safe: no-op if instance already in_progress. '
  'A new pending task is created for the approver at the current step '
  '(delegation rules re-applied). Approver receives a notification.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — Extend workflow_instances_status_check for audit action
-- ════════════════════════════════════════════════════════════════════════════

-- workflow_action_log.action is text (no CHECK constraint), so 'update_started'
-- is valid without schema changes. No additional DDL needed.


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm needs_update is in expense_status enum
SELECT enumlabel FROM pg_enum
JOIN   pg_type ON pg_type.oid = pg_enum.enumtypid
WHERE  pg_type.typname = 'expense_status'
ORDER  BY enumsortorder;

-- Confirm workflow_pending_changes accepts needs_update
SELECT conname, pg_get_constraintdef(oid) AS def
FROM   pg_constraint
WHERE  conname = 'workflow_pending_changes_status_check';

-- Confirm both RPCs exist
SELECT proname, prosrc LIKE '%needs_update%' AS handles_needs_update
FROM   pg_proc
WHERE  proname IN ('wf_prepare_update', 'wf_resubmit', 'wf_sync_module_status')
ORDER  BY proname;

-- =============================================================================
-- END OF MIGRATION 180
-- =============================================================================
