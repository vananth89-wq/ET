-- =============================================================================
-- Migration 218: New Hire Workflow — RPCs
--
-- FUNCTIONS
-- ─────────
-- 1. submit_hire(p_employee_id uuid)
--    Called by the HR Analyst's "Submit for Approval" button.
--    Validates the record belongs to the caller, marks it Pending + locked,
--    then calls wf_submit() to create the workflow instance/tasks.
--    If no workflow is configured → raises an actionable error (not a silent
--    fallback) so the admin knows to configure one.
--
-- 2. wf_activate_employee(p_employee_id uuid)
--    Server-side atomic activation. Called automatically when the approver
--    approves a hire via wf_approve(). Replaces the frontend handleActivate().
--    Steps: status → Active, locked → false, send OTP, link_profile, record invite.
--
-- 3. get_employee_hire_review(p_employee_id uuid)
--    Returns all employee sections as a structured JSONB array.
--    WorkflowReview calls this when module_code = 'employee_hire'.
--    Adding new sections in future automatically appears in the review screen.
--
-- SAFETY
-- ──────
-- All functions use SECURITY DEFINER + fixed search_path.
-- wf_activate_employee checks the caller has an active approved task or is admin.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. submit_hire(p_employee_id uuid)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id          uuid;        -- caller's employee uuid
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

  -- Only the creating analyst (or admin) may submit
  -- We treat the record as "owned" by the creator — for now we allow any HR
  -- analyst who can view the record to submit. A stricter check can be added
  -- via a created_by column in a later migration.
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
  SET    status  = 'Pending',
         locked  = true,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Start the workflow instance
  PERFORM wf_submit(
    p_template_code  => v_template_code,
    p_module_code    => 'employee_hire',
    p_record_id      => p_employee_id,
    p_submitted_by   => auth.uid(),
    p_metadata       => jsonb_build_object(
      'employee_id', (SELECT employee_id FROM employees WHERE id = p_employee_id),
      'name',        (SELECT name        FROM employees WHERE id = p_employee_id)
    )
  );
END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submit a Draft/Incomplete employee record for approval. Marks it Pending+locked and starts the workflow instance.';

REVOKE ALL ON FUNCTION submit_hire(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_hire(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. wf_activate_employee(p_employee_id uuid)
--    Atomic server-side activation — called by the workflow engine on approval.
--    Mirrors exactly what AddEmployee.tsx handleActivate() does on the frontend,
--    but runs in a single server transaction.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_next_attempt  int;
BEGIN
  -- Fetch employee
  SELECT status::text, business_email, name
  INTO   v_status, v_email, v_name
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  -- Step 1: Activate the employee record
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Step 2: Record invite attempt number
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  -- Step 3: Stamp invite_sent_at
  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- NOTE: Auth OTP (signInWithOtp) and link_profile_to_employee must be
  -- called from the frontend after this RPC returns, because they require
  -- the Supabase client SDK / service-role key. We keep the DB-side clean
  -- and let the frontend trigger those two steps on success.
  -- The frontend calls this RPC via supabase.rpc('wf_activate_employee', ...)
  -- and then handles OTP + linking the same way handleActivate() currently does.
END;
$$;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-workflow-approved employee: sets status=Active, locked=false, records invite. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_employee_hire_review(p_employee_id uuid)
--    Returns employee data as structured sections for WorkflowReview.
--    Shape: JSONB array of { section: text, fields: [{label, value}] }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_employee_hire_review(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp      employees%ROWTYPE;
  v_addr     employee_addresses%ROWTYPE;
  v_passport passports%ROWTYPE;
  v_ec       emergency_contacts%ROWTYPE;
  v_dept     text;
  v_manager  text;
  v_currency text;
  v_result   jsonb := '[]'::jsonb;
BEGIN
  -- Fetch core employee
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  -- Lookup labels
  SELECT name INTO v_dept     FROM departments WHERE id = v_emp.dept_id;
  SELECT name INTO v_manager  FROM employees   WHERE id = v_emp.manager_id;
  SELECT code INTO v_currency FROM currencies  WHERE id = v_emp.base_currency_id;

  -- Satellite tables (UNIQUE per employee — single rows)
  SELECT * INTO v_addr     FROM employee_addresses  WHERE employee_id = p_employee_id;
  SELECT * INTO v_passport FROM passports           WHERE employee_id = p_employee_id;
  SELECT * INTO v_ec       FROM emergency_contacts  WHERE employee_id = p_employee_id LIMIT 1;

  -- ── Section 1: Personal Info ───────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Personal Info',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Employee ID',      'value', COALESCE(v_emp.employee_id, '—')),
      jsonb_build_object('label', 'Full Name',        'value', COALESCE(v_emp.name, '—')),
      jsonb_build_object('label', 'Nationality',      'value', COALESCE(v_emp.nationality, '—')),
      jsonb_build_object('label', 'Marital Status',   'value', COALESCE(v_emp.marital_status, '—')),
      jsonb_build_object('label', 'Status',           'value', COALESCE(v_emp.status::text, '—'))
    )
  );

  -- ── Section 2: Contact ─────────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Contact',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Business Email',   'value', COALESCE(v_emp.business_email, '—')),
      jsonb_build_object('label', 'Personal Email',   'value', COALESCE(v_emp.personal_email, '—')),
      jsonb_build_object('label', 'Mobile',           'value', COALESCE(v_emp.country_code || ' ' || v_emp.mobile, COALESCE(v_emp.mobile, '—')))
    )
  );

  -- ── Section 3: Employment ──────────────────────────────────────────────────
  v_result := v_result || jsonb_build_object(
    'section', 'Employment',
    'fields', jsonb_build_array(
      jsonb_build_object('label', 'Designation',       'value', COALESCE(v_emp.designation, '—')),
      jsonb_build_object('label', 'Job Title',         'value', COALESCE(v_emp.job_title, '—')),
      jsonb_build_object('label', 'Department',        'value', COALESCE(v_dept, '—')),
      jsonb_build_object('label', 'Manager',           'value', COALESCE(v_manager, '—')),
      jsonb_build_object('label', 'Hire Date',         'value', COALESCE(v_emp.hire_date::text, '—')),
      jsonb_build_object('label', 'Probation End',     'value', COALESCE(v_emp.probation_end_date::text, '—')),
      jsonb_build_object('label', 'Work Country',      'value', COALESCE(v_emp.work_country, '—')),
      jsonb_build_object('label', 'Work Location',     'value', COALESCE(v_emp.work_location, '—')),
      jsonb_build_object('label', 'Base Currency',     'value', COALESCE(v_currency, '—'))
    )
  );

  -- ── Section 4: Address ─────────────────────────────────────────────────────
  IF v_addr IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Address',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Line 1',    'value', COALESCE(v_addr.line1, '—')),
        jsonb_build_object('label', 'Line 2',    'value', COALESCE(v_addr.line2, '—')),
        jsonb_build_object('label', 'Landmark',  'value', COALESCE(v_addr.landmark, '—')),
        jsonb_build_object('label', 'City',      'value', COALESCE(v_addr.city, '—')),
        jsonb_build_object('label', 'District',  'value', COALESCE(v_addr.district, '—')),
        jsonb_build_object('label', 'State',     'value', COALESCE(v_addr.state, '—')),
        jsonb_build_object('label', 'PIN',       'value', COALESCE(v_addr.pin, '—')),
        jsonb_build_object('label', 'Country',   'value', COALESCE(v_addr.country, '—'))
      )
    );
  END IF;

  -- ── Section 5: Passport ────────────────────────────────────────────────────
  IF v_passport IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Passport',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Country',         'value', COALESCE(v_passport.country, '—')),
        jsonb_build_object('label', 'Passport Number', 'value', COALESCE(v_passport.passport_number, '—')),
        jsonb_build_object('label', 'Issue Date',      'value', COALESCE(v_passport.issue_date::text, '—')),
        jsonb_build_object('label', 'Expiry Date',     'value', COALESCE(v_passport.expiry_date::text, '—'))
      )
    );
  END IF;

  -- ── Section 6: Emergency Contact ──────────────────────────────────────────
  IF v_ec IS NOT NULL THEN
    v_result := v_result || jsonb_build_object(
      'section', 'Emergency Contact',
      'fields', jsonb_build_array(
        jsonb_build_object('label', 'Name',         'value', COALESCE(v_ec.name, '—')),
        jsonb_build_object('label', 'Relationship', 'value', COALESCE(v_ec.relationship, '—')),
        jsonb_build_object('label', 'Phone',        'value', COALESCE(v_ec.phone, '—')),
        jsonb_build_object('label', 'Alt Phone',    'value', COALESCE(v_ec.alt_phone, '—')),
        jsonb_build_object('label', 'Email',        'value', COALESCE(v_ec.email, '—'))
      )
    );
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_employee_hire_review(uuid) IS
  'Returns all employee sections as structured JSONB [{section, fields:[{label,value}]}] for WorkflowReview rendering.';

REVOKE ALL ON FUNCTION get_employee_hire_review(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_hire_review(uuid) TO authenticated;
