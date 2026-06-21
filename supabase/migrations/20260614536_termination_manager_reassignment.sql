-- =============================================================================
-- Migration 536: Direct-report manager reassignment on termination
--
-- FEATURE
-- ───────
-- When HR submits a termination and selects new managers for direct reports,
-- store those reassignments on the termination record. When the termination
-- executes (fn_finalize_termination_execution), apply each reassignment as a
-- new employee_employment slice effective from last_working_date + 1.
--
-- CHANGES
-- ───────
-- 1. Add direct_report_reassignments jsonb column to employee_terminations
-- 2. Update submit_termination() to accept p_reassignments parameter
-- 3. Update fn_finalize_termination_execution() to apply reassignments on exec
-- =============================================================================


-- =============================================================================
-- 1. Add column
-- =============================================================================

ALTER TABLE employee_terminations
  ADD COLUMN IF NOT EXISTS direct_report_reassignments jsonb NOT NULL DEFAULT '[]';

COMMENT ON COLUMN employee_terminations.direct_report_reassignments IS
  'Array of {employee_id, new_manager_id} objects. Applied by fn_finalize_termination_execution '
  'as new employee_employment slices effective from last_working_date + 1.';


-- =============================================================================
-- 2. submit_termination — accept p_reassignments
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]',
  p_comment          text  DEFAULT NULL,
  p_reassignments    jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Initiation
  v_initiation_type           text;

  -- Payload fields
  v_separation_date           date;
  v_reason_code               text;
  v_last_working_date         date;
  v_waived                    boolean;
  v_waiver_reason             text;
  v_eligible_for_rehire       boolean;
  v_regrettable               boolean;
  v_comments                  text;

  -- Notice period
  v_notice_period_days        int;
  v_notice_expiry_date        date;

  -- Workflow
  v_template_code             text;
  v_template_id               uuid;
  v_termination_id            uuid;
  v_instance_id               uuid;
  v_wf_result                 jsonb;
BEGIN

  -- ── 1. Derive initiation type ──────────────────────────────────────────────
  v_initiation_type := derive_termination_initiation_type(p_employee_id);

  -- ── 2. Permission gate ─────────────────────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    IF NOT (
      user_can('termination', 'edit', p_employee_id)
      OR user_can('termination', 'edit', NULL)
      OR get_my_employee_id() = p_employee_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
    END IF;
  ELSE
    IF NOT (
      user_can('termination', 'edit', p_employee_id)
      OR user_can('termination', 'edit', NULL)
      OR get_my_employee_id() = p_employee_id
      OR EXISTS (
           SELECT 1 FROM employees
           WHERE  id         = p_employee_id
             AND  manager_id = get_my_employee_id()
         )
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
    END IF;
  END IF;

  -- ── 3. Extract payload ─────────────────────────────────────────────────────
  v_separation_date     := (p_termination_data->>'separation_date')::date;
  v_reason_code         :=  p_termination_data->>'termination_reason_code';
  v_last_working_date   := COALESCE(
                             (p_termination_data->>'last_working_date')::date,
                             v_separation_date
                           );
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       :=  p_termination_data->>'notice_period_waiver_reason';
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            :=  p_termination_data->>'comments';

  -- ── 4. Validation ──────────────────────────────────────────────────────────
  IF v_separation_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'separation_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;

  -- ── 5. Notice period snapshot ──────────────────────────────────────────────
  SELECT COALESCE(notice_period_days, 30) INTO v_notice_period_days
  FROM   employees WHERE id = p_employee_id;

  v_notice_expiry_date := v_separation_date + (v_notice_period_days || ' days')::interval;

  -- ── 6. Duplicate guard ─────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM employee_terminations
    WHERE  employee_id     = p_employee_id
      AND  workflow_status NOT IN ('WITHDRAWN', 'REJECTED')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'An active termination already exists for this employee.');
  END IF;

  -- ── 7. Resolve workflow template ───────────────────────────────────────────
  v_template_code := CASE v_initiation_type
    WHEN 'SELF'           THEN 'termination_self'
    WHEN 'HR_INITIATED'   THEN 'termination_hr'
    WHEN 'ADMIN_INITIATED'THEN 'termination_hr'
    ELSE                       'termination_hr'
  END;

  -- ── 8. Fetch template id (may be NULL if no workflow configured) ────────────
  SELECT id INTO v_template_id
  FROM   workflow_templates
  WHERE  code       = v_template_code
    AND  is_active  = true
  LIMIT  1;

  -- ── 9. Insert DRAFT row ────────────────────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id,
    separation_date,
    notice_expiry_date,
    notice_period_days_snapshot,
    last_working_date,
    termination_reason_code,
    termination_initiation_type,
    notice_period_waived,
    notice_period_waiver_reason,
    eligible_for_rehire,
    regrettable_termination,
    comments,
    direct_report_reassignments,
    workflow_status,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    v_separation_date,
    v_notice_expiry_date,
    v_notice_period_days,
    v_last_working_date,
    v_reason_code,
    v_initiation_type,
    v_waived,
    v_waiver_reason,
    v_eligible_for_rehire,
    v_regrettable,
    v_comments,
    COALESCE(p_reassignments, '[]'::jsonb),
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 10. Workflow path vs direct-save path ──────────────────────────────────
  IF v_template_id IS NULL THEN
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED', updated_at = now()
    WHERE  id = v_termination_id;

    RETURN jsonb_build_object(
      'ok',            true,
      'termination_id',v_termination_id,
      'workflow',      false
    );
  END IF;

  -- ── 11. Launch workflow ────────────────────────────────────────────────────
  v_wf_result := wf_submit(
    p_template_code   => v_template_code,
    p_module_code     => 'termination',
    p_record_id       => v_termination_id,
    p_metadata        => jsonb_build_object(
                           'employee_id',   p_employee_id,
                           'separation_date', v_separation_date,
                           'reason_code',   v_reason_code,
                           'last_working_date', v_last_working_date,
                           'initiation_type', v_initiation_type
                         ),
    p_comment         => p_comment,
    p_subject_profile_id => (SELECT id FROM profiles WHERE employee_id = p_employee_id LIMIT 1)
  );

  IF NOT (v_wf_result->>'ok')::boolean THEN
    -- Roll back termination row and bubble up error
    DELETE FROM employee_terminations WHERE id = v_termination_id;
    RETURN v_wf_result;
  END IF;

  v_instance_id := (v_wf_result->>'instance_id')::uuid;

  UPDATE employee_terminations
  SET    workflow_instance_id = v_instance_id,
         workflow_status      = 'PENDING',
         updated_at           = now()
  WHERE  id = v_termination_id;

  RETURN jsonb_build_object(
    'ok',              true,
    'termination_id',  v_termination_id,
    'instance_id',     v_instance_id,
    'workflow',        true
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) IS
  'Mig 536: added p_reassignments — stores direct-report manager reassignments on the record. '
  'Applied by fn_finalize_termination_execution as new employment slices from lwd+1.';


-- =============================================================================
-- 3. fn_finalize_termination_execution — apply reassignments
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_finalize_termination_execution(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_term          RECORD;
  v_lwd           date;
  v_today         date := CURRENT_DATE;
  v_eff_from      date;       -- lwd + 1
  v_reassignment  jsonb;
  v_dr_emp_id     uuid;
  v_new_mgr_id    uuid;
  v_current_ee    RECORD;     -- current employment slice for direct report
BEGIN
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination not found');
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Termination is not APPROVED (status: %s)', v_term.workflow_status));
  END IF;

  -- Idempotency
  IF v_term.scheduled_executed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'Already executed');
  END IF;

  v_lwd      := COALESCE(v_term.last_working_date, v_term.separation_date);
  v_eff_from := v_lwd + 1;

  -- Guard: only execute on/after last_working_date
  IF v_lwd > v_today THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', format('Future-dated (lwd: %s)', v_lwd));
  END IF;

  -- Bypass the employment mirror guard for this transaction
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- ── Flip employees.status → Inactive ──────────────────────────────────────
  UPDATE employees
  SET    status     = 'Inactive',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  -- ── Apply direct-report manager reassignments ──────────────────────────────
  -- Each entry: { employee_id: <dr uuid>, new_manager_id: <mgr uuid> }
  -- Creates a new employee_employment slice from lwd+1 with the new manager_id.
  -- All other employment fields are copied from the current active slice.

  FOR v_reassignment IN
    SELECT value FROM jsonb_array_elements(
      COALESCE(v_term.direct_report_reassignments, '[]'::jsonb)
    )
  LOOP
    v_dr_emp_id  := (v_reassignment->>'employee_id')::uuid;
    v_new_mgr_id := (v_reassignment->>'new_manager_id')::uuid;

    -- Skip if either ID is missing
    CONTINUE WHEN v_dr_emp_id IS NULL OR v_new_mgr_id IS NULL;

    -- Find the direct report's current open employment slice
    SELECT * INTO v_current_ee
    FROM   employee_employment
    WHERE  employee_id   = v_dr_emp_id
      AND  is_active     = true
      AND  effective_to  = '9999-12-31'
    ORDER  BY effective_from DESC
    LIMIT  1;

    IF NOT FOUND THEN CONTINUE; END IF;

    -- Close the current slice at lwd (the day the old manager leaves)
    UPDATE employee_employment
    SET    effective_to  = v_lwd,
           is_active     = false,
           inactive_at   = now(),
           inactive_by   = auth.uid(),
           updated_by    = auth.uid()
    WHERE  id = v_current_ee.id;

    -- Open a new slice from lwd+1 with new manager_id, all other fields same
    INSERT INTO employee_employment (
      employee_id,
      designation,
      job_title,
      dept_id,
      manager_id,
      hire_date,
      end_date,
      work_country,
      work_location,
      base_currency_id,
      status,
      effective_from,
      effective_to,
      is_active,
      created_by,
      updated_by
    ) VALUES (
      v_dr_emp_id,
      v_current_ee.designation,
      v_current_ee.job_title,
      v_current_ee.dept_id,
      v_new_mgr_id,           -- ← new manager
      v_current_ee.hire_date,
      v_current_ee.end_date,
      v_current_ee.work_country,
      v_current_ee.work_location,
      v_current_ee.base_currency_id,
      v_current_ee.status,
      v_eff_from,             -- ← lwd + 1
      '9999-12-31',
      true,
      auth.uid(),
      auth.uid()
    );

    -- Update the mirror on employees
    UPDATE employees
    SET    manager_id  = v_new_mgr_id,
           updated_at  = now()
    WHERE  id = v_dr_emp_id;

  END LOOP;

  -- ── Stamp execution ────────────────────────────────────────────────────────
  UPDATE employee_terminations
  SET    scheduled_executed    = true,
         scheduled_executed_at = now(),
         updated_at            = now(),
         updated_by            = auth.uid()
  WHERE  id = p_termination_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'employee_id', v_term.employee_id,
    'executed_on', v_today
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_finalize_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_finalize_termination_execution(uuid) TO authenticated;

COMMENT ON FUNCTION fn_finalize_termination_execution(uuid) IS
  'Mig 536: flips employee Inactive, then applies direct_report_reassignments — '
  'each creates a new employee_employment slice from last_working_date+1 with the '
  'selected new manager_id. Mirror (employees.manager_id) also updated. Idempotent.';

-- =============================================================================
-- END OF MIGRATION 536
-- =============================================================================
