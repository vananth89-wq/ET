-- Migration 254: Use edit_all_pending as the submit-on-behalf bypass in submit_hire
--               + add employees.submitted_at column
--               + backend required-field validation
-- ─────────────────────────────────────────────────────────────────────────────
--
-- CHANGES
-- 1. Replace dead hire_employee.approve bypass with hire_employee.edit_all_pending.
-- 2. Add employees.submitted_at (timestamptz, nullable) — stamped by submit_hire
--    at the moment of actual submission so WorkflowReview shows the correct date
--    instead of created_at (when the Draft was first saved).
-- 3. Restore duplicate-instance guard removed in mig 247.
-- 4. Add backend required-field validation (personal/contact/email/employment/
--    address/emergency) to prevent partial records bypassing the UI.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Schema: add submitted_at column ──────────────────────────────────────────
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ DEFAULT NULL;

COMMENT ON COLUMN employees.submitted_at IS
  'Timestamp set by submit_hire() at the moment the HR analyst submits the hire '
  'record for approval (or direct activation). NULL for records that have not yet '
  'been submitted. Distinct from created_at (when the Draft was first saved).';

-- ─────────────────────────────────────────────────────────────────────────────

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
  v_missing        text[] := '{}';
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
  -- Allow:  creator of the record
  --         any user with hire_employee.edit_all_pending (HR Head / admin)
  --         super admins
  -- Deny:   other HR analysts who can view but didn't create this record
  -- NULL created_by (legacy / pre-mig 253 records) → unclaimed, anyone may submit
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

  -- ── 4. Backend required-field validation ─────────────────────────────────
  -- Mirror the 6 required sections from the frontend (personal, contact, email,
  -- employment, address, emergency). Optional sections (identity, passport) are
  -- not checked. Prevents partial records from bypassing the UI validation via
  -- a direct RPC call.

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

  -- email: business_email on employees base table (loaded into v_emp in step 1)
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    v_missing := array_append(v_missing, 'Email');
  END IF;

  -- employment: designation + hire_date + work_country + work_location on base table
  IF v_emp.designation IS NULL OR v_emp.hire_date IS NULL
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

    -- Stamp submitted_at before activating (wf_activate_employee doesn't set it)
    UPDATE employees SET submitted_at = NOW() WHERE id = p_employee_id;

    -- No workflow — activate immediately
    PERFORM wf_activate_employee(p_employee_id);

  ELSE
    RAISE EXCEPTION 'Unexpected submission mode: %', v_mode
      USING ERRCODE = 'internal_error';
  END IF;

END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submits a Draft or Incomplete hire record for approval (workflow mode) or activates '
  'it directly (direct mode). Ownership: only the creator, a user with '
  'hire_employee.edit_all_pending, or a super admin may submit. '
  'Replaces the defunct hire_employee.approve bypass (mig 253) with the already-seeded '
  'edit_all_pending permission which HR Head holds.';
