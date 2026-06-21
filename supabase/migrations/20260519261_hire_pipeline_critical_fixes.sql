-- Migration 261: Critical + High fixes found during post-gap audit
-- ─────────────────────────────────────────────────────────────────────────────
--
-- ISSUES ADDRESSED
-- ────────────────
-- A (Critical) submit_hire workflow path is completely broken:
--      1. Calls wf_fan_out_tasks() which does not exist anywhere.
--      2. Uses "reference_id" column — physical column is "record_id".
--      3. Calls wf_queue_notification with 5 args — function takes 4.
--      4. Inserts workflow_instances with status='pending' — wf_submit uses
--         'in_progress'.  Duplicate-instance guard uses wrong column name too.
--   FIX: revert workflow path to delegate entirely to wf_submit() (as mig 224
--   did), which handles instance creation, approver resolution, multi-approver
--   fan-out, audit log, first-approver notification, and
--   wf_sync_module_status('submitted').  submit_hire only needs to:
--     a. Validate + check ownership/status (kept from mig 253/254/260).
--     b. Call wf_submit with the resolved template code.
--     c. Stamp submitted_at (wf_sync_module_status does not set this column).
--     d. Queue hire.submitted to the initiator.
--
-- B (Critical) wf_withdraw uses "reference_id" (should be "record_id") and
--   "assignee_id" (should be "assigned_to") — both fail with 42703 at runtime,
--   breaking every hire withdrawal after mig 255.
--   FIX: correct both column names throughout wf_withdraw.
--
-- C (High) hire.submitted notification template was never seeded.
--   wf_queue_notification silently no-ops when the template is missing.
--   FIX: seed the template.
--
-- D (High) wf_resubmit bypass uses has_role('admin') only.
--   submit_hire allows HR Head (hire_employee.edit_all_pending) to submit on
--   behalf, but wf_resubmit does not — inconsistent.
--   FIX: add user_can('hire_employee', 'edit_all_pending', NULL) to the bypass.
--
-- E (Medium) wf_resubmit sets search_path = public without auth — inconsistent
--   with other hire functions that call auth.uid().
--   FIX: add auth to search_path.
--
-- F (Medium) employees_update RLS WITH CHECK has an activation branch that
--   allows any user with hire_employee.create to directly UPDATE status='Active',
--   bypassing wf_activate_employee entirely. wf_activate_employee is SECURITY
--   DEFINER and bypasses RLS, so this branch is never needed for the normal path.
--   FIX: remove the activation branch from WITH CHECK only (USING unchanged).
--
-- G (Medium) validate_hire_fields is SECURITY DEFINER but granted to
--   authenticated, allowing any user to probe field-completeness of any record.
--   It is only called from other SECURITY DEFINER functions.
--   FIX: revoke the authenticated grant; called functions retain access via
--   their own SECURITY DEFINER privilege.
-- ─────────────────────────────────────────────────────────────────────────────


-- ════════════════════════════════════════════════════════════════════════════
-- FIX C: seed hire.submitted template
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES (
  'hire.submitted',
  'Hire request submitted: {{name}}',
  'Your new hire request for {{name}} ({{employee_id}}) has been submitted '
  'for approval and is now pending review by the assigned approvers.'
)
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ════════════════════════════════════════════════════════════════════════════
-- FIX A: rewrite submit_hire — delegate workflow path to wf_submit
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_emp            employees%ROWTYPE;
  v_created_by     uuid;
  v_wf_template_id uuid;
  v_template_code  text;
  v_instance_id    uuid;
  v_mode           text;
BEGIN
  -- ── 1. Load employee record ───────────────────────────────────────────────
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee record not found.' USING ERRCODE = 'no_data_found';
  END IF;

  -- ── 2. Status gate ────────────────────────────────────────────────────────
  IF v_emp.status NOT IN ('Draft', 'Incomplete') THEN
    RAISE EXCEPTION
      'Only Draft or Incomplete hire records can be submitted (current status: %).',
      v_emp.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 3. Ownership check ────────────────────────────────────────────────────
  -- Allow: creator, HR Head (edit_all_pending), super admin.
  -- Legacy records (created_by IS NULL, pre-mig 253): anyone may submit.
  v_created_by := v_emp.created_by;
  IF v_created_by IS NOT NULL
    AND v_created_by != auth.uid()
    AND NOT user_can('hire_employee', 'edit_all_pending', NULL)
    AND NOT is_super_admin()
  THEN
    RAISE EXCEPTION
      'Only the HR Analyst who created this hire record may submit it for approval. '
      'If you need to submit on their behalf, ask an HR Head or administrator.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 4. Required-field validation ─────────────────────────────────────────
  PERFORM validate_hire_fields(p_employee_id);

  -- ── 5. Resolve submission mode ────────────────────────────────────────────
  v_mode := get_hire_submission_mode(p_employee_id);

  -- ── 5a. WORKFLOW mode ─────────────────────────────────────────────────────
  IF v_mode = 'workflow' THEN

    v_wf_template_id := resolve_workflow_for_submission('employee_hire', auth.uid());
    IF v_wf_template_id IS NULL THEN
      RAISE EXCEPTION
        'No active workflow template found for employee_hire. '
        'Please configure one in Workflow Templates before submitting.'
        USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_wf_template_id;

    -- Delegate to wf_submit: handles instance creation, approver resolution,
    -- multi-approver fan-out, audit log, first-approver task_assigned
    -- notification, duplicate-instance guard, and
    -- wf_sync_module_status('submitted') → sets Pending+locked=true.
    PERFORM wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'employee_hire',
      p_record_id     => p_employee_id,
      p_metadata      => jsonb_build_object(
        'employee_id', v_emp.employee_id,
        'name',        v_emp.name
      )
    );

    -- Stamp submitted_at (wf_sync_module_status does not set this column).
    UPDATE employees SET submitted_at = NOW() WHERE id = p_employee_id;

    -- Notify the initiator that their submission was received.
    -- The instance was just created by wf_submit — find it.
    SELECT id INTO v_instance_id
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_instance_id IS NOT NULL THEN
      PERFORM wf_queue_notification(
        v_instance_id,
        'hire.submitted',
        auth.uid(),
        '{}'::jsonb
      );
    END IF;

  -- ── 5b. DIRECT mode ───────────────────────────────────────────────────────
  ELSIF v_mode = 'direct' THEN

    -- Stamp submitted_at before activating (wf_activate_employee doesn't set it).
    UPDATE employees SET submitted_at = NOW() WHERE id = p_employee_id;
    PERFORM wf_activate_employee(p_employee_id);

  ELSE
    RAISE EXCEPTION 'Unexpected submission mode: %', v_mode
      USING ERRCODE = 'internal_error';
  END IF;

END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submits a Draft or Incomplete hire record for approval (workflow mode) or '
  'activates it directly (direct mode). '
  'Ownership: only the creator, a user with hire_employee.edit_all_pending, or '
  'a super admin may submit. '
  'Mig 261: reverted workflow path to delegate to wf_submit() (handles instance '
  'creation, task fan-out, duplicate guard, wf_sync_module_status). '
  'submit_hire then stamps submitted_at and queues hire.submitted to the initiator.';


-- ════════════════════════════════════════════════════════════════════════════
-- FIX B: rewrite wf_withdraw — correct reference_id → record_id,
--                               assignee_id → assigned_to
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_withdraw(p_instance_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_instance  RECORD;
  v_assignees uuid[];
  v_assignee  uuid;
BEGIN
  SELECT id, submitted_by, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_withdraw: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION
      'wf_withdraw: instance cannot be withdrawn (status: %)', v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter can withdraw this request';
  END IF;

  -- Collect pending assignees before cancelling (for notification).
  -- Scoped to employee_hire only — other modules can extend this.
  IF v_instance.module_code = 'employee_hire' THEN
    SELECT array_agg(DISTINCT assigned_to)
    INTO   v_assignees
    FROM   workflow_tasks
    WHERE  instance_id = p_instance_id
      AND  status      = 'pending'
      AND  assigned_to IS NOT NULL;
  END IF;

  -- Cancel all pending tasks
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- Mark instance withdrawn
  UPDATE workflow_instances
  SET    status     = 'withdrawn',
         updated_at = now()
  WHERE  id = p_instance_id;

  -- Sync module record back to draft/editable state
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'draft'
  );

  -- Notify each pending assignee that the request was withdrawn
  IF v_assignees IS NOT NULL THEN
    FOREACH v_assignee IN ARRAY v_assignees LOOP
      PERFORM wf_queue_notification(
        p_instance_id,
        'hire.withdrawn',
        v_assignee,
        '{}'::jsonb
      );
    END LOOP;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid) IS
  'Withdraws an in-progress or awaiting-clarification workflow instance. '
  'Cancels all pending tasks, marks the instance withdrawn, and syncs the '
  'module record back to draft/editable state. '
  'For employee_hire: notifies each pending-task assignee via hire.withdrawn. '
  'Mig 261: fixed reference_id → record_id and assignee_id → assigned_to '
  '(both caused 42703 errors in mig 255).';


-- ════════════════════════════════════════════════════════════════════════════
-- FIX D + E: rewrite wf_resubmit — add edit_all_pending bypass + fix search_path
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id   uuid,
  p_response      text  DEFAULT NULL,
  p_proposed_data jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
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

  -- Bypass: original submitter, HR Head (edit_all_pending), or admin role.
  IF v_instance.submitted_by != auth.uid()
    AND NOT user_can('hire_employee', 'edit_all_pending', NULL)
    AND NOT has_role('admin')
  THEN
    RAISE EXCEPTION 'wf_resubmit: only the original submitter (or an HR Head / admin) can resubmit';
  END IF;

  -- ── Module-level required-field validation ────────────────────────────────
  IF v_instance.module_code = 'employee_hire' THEN
    PERFORM validate_hire_fields(v_instance.record_id);
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

  -- ── Cancel any stray pending tasks ────────────────────────────────────────
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

  -- ── Re-lock the module record (employee_hire → Pending+locked=true) ───────
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
  'Bypass: original submitter, HR Head (hire_employee.edit_all_pending), or admin. '
  'Calls wf_sync_module_status(submitted) to re-lock the module record. '
  'Calls validate_hire_fields() for employee_hire before restarting. '
  'Mig 261: added edit_all_pending bypass (D); fixed search_path to include auth (E).';


-- ════════════════════════════════════════════════════════════════════════════
-- FIX F: employees_update RLS — remove activation branch from WITH CHECK
-- ════════════════════════════════════════════════════════════════════════════
-- wf_activate_employee is SECURITY DEFINER and bypasses RLS entirely, so the
-- WITH CHECK activation branch is never used for the normal path. Keeping it
-- creates an unintended direct-UPDATE path to status='Active' for anyone with
-- hire_employee.create. USING is left unchanged (read access is fine).

DROP POLICY IF EXISTS employees_update ON employees;

CREATE POLICY employees_update ON employees FOR UPDATE
  USING (
    user_can('personal_info', 'edit', id)
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))
    OR (status IN ('Draft', 'Incomplete')
        AND user_can('hire_employee', 'edit', NULL)
        AND (
          created_by IS NULL
          OR created_by = auth.uid()
          OR user_can('hire_employee', 'edit_all_pending', NULL)
          OR is_super_admin()
        ))
    OR (status = 'Pending'
        AND (user_can('hire_employee', 'edit_all_pending', NULL) OR is_super_admin()))
  )
  WITH CHECK (
    user_can('personal_info', 'edit', id)
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))
    OR (status IN ('Draft', 'Incomplete')
        AND user_can('hire_employee', 'edit', NULL)
        AND (
          created_by IS NULL
          OR created_by = auth.uid()
          OR user_can('hire_employee', 'edit_all_pending', NULL)
          OR is_super_admin()
        ))
    OR (status = 'Pending'
        AND (user_can('hire_employee', 'edit_all_pending', NULL) OR is_super_admin()))
    -- NOTE: No activation branch here. Activation (Pending → Active) is only
    -- done by wf_activate_employee (SECURITY DEFINER, bypasses RLS).
    -- Removing the branch closes a direct-UPDATE-to-Active hole (mig 261 Fix F).
  );

COMMENT ON POLICY employees_update ON employees IS
  'Status-routed UPDATE. '
  'Draft/Incomplete: only creator, HR Head (edit_all_pending), or super admin. '
  'Pending: only HR Head or super admin (approver edits use update_hire_field RPC). '
  'Active: employee_details.edit, deactivation/reactivation via inactive_employees. '
  'Mig 261: removed activation branch from WITH CHECK — activation is SECURITY '
  'DEFINER only (wf_activate_employee), no direct table UPDATE allowed.';


-- ════════════════════════════════════════════════════════════════════════════
-- FIX G: revoke authenticated grant on validate_hire_fields
-- ════════════════════════════════════════════════════════════════════════════
-- Called only from SECURITY DEFINER functions; no need for direct client access.

REVOKE ALL ON FUNCTION validate_hire_fields(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION validate_hire_fields(uuid) FROM authenticated;
-- (The function's owner retains EXECUTE; SECURITY DEFINER callers can still call it.)


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- hire.submitted template seeded
  IF NOT EXISTS (
    SELECT 1 FROM workflow_notification_templates WHERE code = 'hire.submitted'
  ) THEN
    RAISE EXCEPTION 'ABORT: hire.submitted template not found.';
  END IF;

  -- submit_hire present
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'submit_hire'
  ) THEN
    RAISE EXCEPTION 'ABORT: submit_hire not found.';
  END IF;

  -- wf_withdraw present
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'wf_withdraw'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_withdraw not found.';
  END IF;

  -- employees_update policy present
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'employees' AND policyname = 'employees_update' AND cmd = 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'ABORT: employees_update policy not found.';
  END IF;

  RAISE NOTICE 'Migration 261 verified: all fixes applied.';
END;
$$;
