-- Migration 260: Shared validate_hire_fields() + wire into submit_hire & wf_resubmit
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM (Gap 17)
-- submit_hire (mig 254) has backend required-field validation for all 6 required
-- sections. wf_resubmit has none. A resubmission after a send-back can therefore
-- put an incomplete record back under review if:
--   a) Someone calls wf_resubmit directly via RPC (bypasses the frontend check), or
--   b) The frontend validateHireFields() check misfires — it uses `effective === '—'`
--      (an em-dash display convention) as a proxy for "empty", which is fragile.
--
-- SOLUTION
-- 1. Extract the 6-section validation from submit_hire into a standalone
--    SECURITY DEFINER function: validate_hire_fields(p_employee_id uuid).
--    Returns void; raises check_violation if any section is incomplete.
-- 2. Replace the inline validation block in submit_hire with a call to it.
-- 3. Add a call to validate_hire_fields in wf_resubmit, scoped to employee_hire.
--
-- Both paths now enforce the same server-side gate regardless of frontend state.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── Step 1: shared validation function ───────────────────────────────────────

CREATE OR REPLACE FUNCTION validate_hire_fields(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp     employees%ROWTYPE;
  v_missing text[] := '{}';
BEGIN
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'validate_hire_fields: employee % not found.', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- personal: nationality + gender + dob
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id = p_employee_id
      AND  nationality IS NOT NULL
      AND  gender      IS NOT NULL
      AND  dob         IS NOT NULL
  ) THEN v_missing := array_append(v_missing, 'Personal'); END IF;

  -- contact: mobile
  IF NOT EXISTS (
    SELECT 1 FROM employee_contact
    WHERE  employee_id = p_employee_id
      AND  mobile IS NOT NULL AND mobile != ''
  ) THEN v_missing := array_append(v_missing, 'Contact'); END IF;

  -- email: business_email on employees base table
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    v_missing := array_append(v_missing, 'Email');
  END IF;

  -- employment: designation + hire_date + work_country + work_location
  IF v_emp.designation   IS NULL OR v_emp.hire_date     IS NULL
     OR v_emp.work_country IS NULL OR v_emp.work_location IS NULL THEN
    v_missing := array_append(v_missing, 'Employment');
  END IF;

  -- address: line1 + city + pin + country
  IF NOT EXISTS (
    SELECT 1 FROM employee_addresses
    WHERE  employee_id = p_employee_id
      AND  line1   IS NOT NULL AND line1   != ''
      AND  city    IS NOT NULL AND city    != ''
      AND  pin     IS NOT NULL AND pin     != ''
      AND  country IS NOT NULL AND country != ''
  ) THEN v_missing := array_append(v_missing, 'Address'); END IF;

  -- emergency: at least one contact row
  IF NOT EXISTS (
    SELECT 1 FROM emergency_contacts WHERE employee_id = p_employee_id LIMIT 1
  ) THEN v_missing := array_append(v_missing, 'Emergency Contact'); END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'Cannot submit: the following required sections are incomplete: %. '
      'Please complete all required sections before submitting.',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

COMMENT ON FUNCTION validate_hire_fields(uuid) IS
  'Validates all 6 required hire sections (Personal, Contact, Email, Employment, '
  'Address, Emergency Contact) for the given employee record. '
  'Raises check_violation listing every missing section. '
  'Called by both submit_hire and wf_resubmit so both paths enforce the same gate. '
  'Optional sections (Identity Document, Passport) are not checked.';

REVOKE ALL ON FUNCTION validate_hire_fields(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION validate_hire_fields(uuid) TO authenticated;


-- ── Step 2: update submit_hire — replace inline block with shared call ────────
--
-- The inline validation block (step 4 in mig 254) is replaced by a single
-- PERFORM validate_hire_fields(p_employee_id). All other logic is unchanged.

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
  v_instance_id    uuid;
  v_first_step     int;
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

  -- ── 4. Required-field validation (shared) ────────────────────────────────
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

    -- Guard: no duplicate in-flight instance
    IF EXISTS (
      SELECT 1 FROM workflow_instances
      WHERE module_code  = 'employee_hire'
        AND reference_id = p_employee_id
        AND status       NOT IN ('approved', 'rejected', 'withdrawn')
    ) THEN
      RAISE EXCEPTION
        'An approval workflow is already in progress for this hire record.'
        USING ERRCODE = 'unique_violation';
    END IF;

    -- Create workflow instance
    INSERT INTO workflow_instances (
      template_id, module_code, reference_id, submitted_by, status, current_step
    )
    SELECT
      v_wf_template_id,
      'employee_hire',
      p_employee_id,
      auth.uid(),
      'pending',
      MIN(step_order)
    FROM workflow_steps
    WHERE template_id = v_wf_template_id
    RETURNING id, current_step INTO v_instance_id, v_first_step;

    -- Fan out tasks for the first step
    PERFORM wf_fan_out_tasks(v_instance_id, v_first_step);

    -- Lock the employee record, set status to Pending, stamp submitted_at
    UPDATE employees
    SET status       = 'Pending',
        locked       = TRUE,
        submitted_at = NOW()
    WHERE id = p_employee_id;

    -- Queue hire.submitted notification
    PERFORM wf_queue_notification(
      'employee_hire', 'hire.submitted', v_instance_id, auth.uid(), NULL
    );

  -- ── 5b. DIRECT mode ───────────────────────────────────────────────────────
  ELSIF v_mode = 'direct' THEN

    -- Stamp submitted_at before activating
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
  'Ownership: only the creator, a user with hire_employee.edit_all_pending, or a '
  'super admin may submit. '
  'Mig 260: required-field validation delegated to validate_hire_fields().';


-- ── Step 3: update wf_resubmit — add employee_hire validation ─────────────────
--
-- After the ownership/status checks, and before resetting the workflow instance,
-- call validate_hire_fields when the module is employee_hire. Any other module
-- is unaffected — they have no validate_<module>_fields function yet.

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

  -- ── Module-level required-field validation ────────────────────────────────
  -- employee_hire: enforce the same 6-section check as submit_hire so the record
  -- cannot go back under review with missing required fields.
  -- Other modules: extend this block as they add their own validators.
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

  -- ── Re-lock the module record (mig 258) ───────────────────────────────────
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
  'Mig 258: calls wf_sync_module_status(submitted) to re-lock the module record. '
  'Mig 260: calls validate_hire_fields() for employee_hire before restarting, '
  'matching the same server-side gate as submit_hire. '
  'p_proposed_data accepted for forward-compat, not used.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'validate_hire_fields'
  ) THEN
    RAISE EXCEPTION 'ABORT: validate_hire_fields not found after migration.';
  END IF;
  RAISE NOTICE 'Migration 260 verified: validate_hire_fields present.';
END;
$$;
