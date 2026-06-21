-- =============================================================================
-- Migration 537: Fix submit_termination — notice_period_days is on
--   employee_employment, not employees.
--
-- Mig 536 introduced a regression: the SELECT in step 5 queried
--   SELECT COALESCE(notice_period_days, 30) FROM employees WHERE id = ...
-- but notice_period_days lives on employee_employment (added in mig 483).
-- This caused "column notice_period_days does not exist" on every submission.
--
-- Fix: query the current open employment slice (effective_to = '9999-12-31'),
-- falling back to 30 if none found.
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
  v_wf_result := wf_submit(
    p_template_code   => v_template_code,
    p_module_code     => 'termination',
    p_record_id       => v_termination_id,
    p_metadata        => jsonb_build_object(
                           'employee_id',     p_employee_id,
                           'separation_date', v_separation_date,
                           'reason_code',     v_reason_code,
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
  'Mig 537: fixed notice_period_days query — reads from employee_employment '
  '(current open slice) not employees table. Column added in mig 483.';

-- =============================================================================
-- END OF MIGRATION 537
-- =============================================================================
