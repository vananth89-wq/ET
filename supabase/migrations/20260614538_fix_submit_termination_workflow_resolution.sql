-- =============================================================================
-- Migration 538: Fix submit_termination — restore resolve_workflow_for_submission
--
-- PROBLEM
-- ───────
-- Mig 536 replaced the correct resolve_workflow_for_submission() pattern with
-- a hardcoded template code lookup (code = 'termination_hr'). When the DB has
-- no template with exactly that code, v_template_id is NULL → direct-save path
-- → workflow_status = 'APPROVED' immediately, even though the WorkflowSubmitModal
-- showed a configured approval chain.
--
-- FIX
-- ───
-- Restore the resolve_workflow_for_submission pattern from mig 492. This reads
-- the admin-configured Workflow Assignment for module 'termination' and the
-- submitting user, returning the template_id (or NULL = no workflow assigned).
-- All other fields from mig 537 are kept: p_reassignments, p_comment,
-- separation_date column names, notice_period_days from employee_employment.
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
  v_template_id               uuid;
  v_template_code             text;
  v_has_workflow              boolean;
  v_termination_id            uuid;
  v_instance_id               uuid;
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

  -- ── 5. Notice period snapshot (from employee_employment current open slice) ─
  SELECT COALESCE(ee.notice_period_days, 30)
  INTO   v_notice_period_days
  FROM   employee_employment ee
  WHERE  ee.employee_id  = p_employee_id
    AND  ee.effective_to = '9999-12-31'::date
    AND  ee.is_active    = true
  ORDER  BY ee.effective_from DESC
  LIMIT  1;

  v_notice_period_days := COALESCE(v_notice_period_days, 30);
  v_notice_expiry_date := v_separation_date + (v_notice_period_days || ' days')::interval;

  -- ── 6. Duplicate guard ─────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM employee_terminations
    WHERE  employee_id     = p_employee_id
      AND  workflow_status NOT IN ('WITHDRAWN', 'REJECTED', 'REVERSED')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'An active termination already exists for this employee.');
  END IF;

  -- ── 7. Resolve workflow assignment ────────────────────────────────────────
  -- Uses the same resolve_workflow_for_submission pattern as all other modules.
  -- Admin configures the assignment in Workflow → Assignments UI.
  -- NULL = no assignment configured → direct-save path (status = APPROVED).
  v_template_id  := resolve_workflow_for_submission('termination', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 8. Insert DRAFT row ────────────────────────────────────────────────────
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

  -- ── 9. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    -- Workflow configured → submit to approval queue → PENDING
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_termination_id,
      p_metadata      => jsonb_build_object(
                           'employee_id',       p_employee_id,
                           'separation_date',   v_separation_date,
                           'reason_code',       v_reason_code,
                           'last_working_date', v_last_working_date,
                           'initiation_type',   v_initiation_type
                         ),
      p_comment       => p_comment
    );

    UPDATE employee_terminations
    SET    workflow_instance_id = v_instance_id,
           workflow_status      = 'PENDING',
           updated_at           = now()
    WHERE  id = v_termination_id;

  ELSE
    -- No workflow assigned → direct-save → APPROVED immediately.
    -- fn_finalize_termination_execution runs on/after last_working_date.
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED',
           approved_at    = now(),
           approved_by    = auth.uid(),
           updated_at     = now(),
           updated_by     = auth.uid()
    WHERE  id = v_termination_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'termination_id',  v_termination_id,
    'instance_id',     v_instance_id,
    'workflow',        v_has_workflow,
    'workflow_status', CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb, text, jsonb) IS
  'Mig 538: restored resolve_workflow_for_submission (mig 536 had broken hardcoded template code lookup). '
  'Keeps mig 536 additions: p_reassignments, p_comment, direct_report_reassignments column. '
  'Keeps mig 537 fix: notice_period_days read from employee_employment, not employees.';

-- =============================================================================
-- END OF MIGRATION 538
-- =============================================================================
