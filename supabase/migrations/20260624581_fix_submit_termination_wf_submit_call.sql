-- =============================================================================
-- Migration 575: Fix submit_termination — wf_submit call issues
--
-- Three bugs in mig 537's wf_submit() call:
--
-- 1. Wrong named parameter: p_subject_profile_id (does not exist in wf_submit).
--    wf_submit expects p_subject_employee_id (the employees.id UUID).
--    Because the param name didn't match, p_subject_employee_id was NULL, so
--    initiated_by_actor_id was never stamped and subject_profile_id = submitter.
--    Result: ApproverInbox "On behalf of" block never appeared for HR-initiated
--    terminations; approvers couldn't tell whose termination they were reviewing.
--
-- 2. Wrong variable type for wf_submit return value: v_wf_result was declared
--    jsonb, but wf_submit returns uuid. PG silently coerced uuid → jsonb text,
--    so v_wf_result->>'instance_id' was always NULL, and workflow_instance_id
--    was set to NULL on every submitted termination.
--
-- 3. Missing employee_name in metadata: approvers could not see the terminated
--    employee's name in the portlet title or the TERMINATION DETAILS card.
--
-- Fix:
--   • Use p_subject_employee_id => p_employee_id (correct param + value).
--   • Assign wf_submit return value directly to v_instance_id (uuid).
--   • Remove stale jsonb-result ok/error check (wf_submit raises on failure).
--   • Look up employee name and add it to metadata so the portlet title and
--     enrichment card can display it.
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
  v_employee_name             text;

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
  v_instance_id               uuid;   -- wf_submit returns uuid directly
BEGIN

  -- ── 1. Derive initiation type ──────────────────────────────────────────────
  v_initiation_type := derive_termination_initiation_type(p_employee_id);

  -- ── 1b. Fetch employee name for metadata ───────────────────────────────────
  SELECT name INTO v_employee_name FROM employees WHERE id = p_employee_id;

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

  -- ── 5. Notice period snapshot (from employee_employment, not employees) ────
  SELECT COALESCE(ee.notice_period_days, 30)
  INTO   v_notice_period_days
  FROM   employee_employment ee
  WHERE  ee.employee_id  = p_employee_id
    AND  ee.effective_to = '9999-12-31'::date
    AND  ee.is_active    = true
  ORDER  BY ee.effective_from DESC
  LIMIT  1;

  -- Fallback if no open slice found
  v_notice_period_days := COALESCE(v_notice_period_days, 30);

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
  -- wf_submit returns uuid (the workflow_instance id) and raises on failure.
  -- Pass p_subject_employee_id so wf_submit stamps initiated_by_actor_id when
  -- the submitter (HR/manager) differs from the terminated employee.
  v_instance_id := wf_submit(
    p_template_code       => v_template_code,
    p_module_code         => 'termination',
    p_record_id           => v_termination_id,
    p_metadata            => jsonb_build_object(
                               'employee_id',       p_employee_id,
                               'employee_name',     v_employee_name,
                               'separation_date',   v_separation_date,
                               'reason_code',       v_reason_code,
                               'last_working_date', v_last_working_date,
                               'initiation_type',   v_initiation_type
                             ),
    p_comment             => p_comment,
    p_subject_employee_id => p_employee_id
  );

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
  'Mig 575: fixed wf_submit call — p_subject_employee_id (was wrong p_subject_profile_id), '
  'direct uuid return (was jsonb), added employee_name to metadata.';
