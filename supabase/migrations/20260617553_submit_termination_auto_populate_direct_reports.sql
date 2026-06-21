-- =============================================================================
-- Migration 551: Auto-populate direct_report_reassignments in submit_termination
--
-- When p_reassignments is empty (not passed by caller), fetch the employee's
-- current direct reports from employee_employment and pre-fill the JSONB array so
-- the approver sees them in WorkflowReview.  Each entry has:
--   { employee_id, employee_name, new_manager_id: null, new_manager_name: null }
--
-- This is additive — callers that pass explicit reassignments are unaffected.
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id              uuid,
  p_separation_date          date,
  p_reason_code              text,
  p_initiation_type          text             DEFAULT 'HR',
  p_notice_period_waiver     boolean          DEFAULT false,
  p_waiver_reason            text             DEFAULT NULL,
  p_eligible_for_rehire      boolean          DEFAULT true,
  p_regrettable              boolean          DEFAULT false,
  p_comments                 text             DEFAULT NULL,
  p_reassignments            jsonb            DEFAULT '[]',
  p_comment                  text             DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_notice_period_days   int;
  v_notice_expiry_date   date;
  v_last_working_date    date;
  v_waived               boolean;
  v_waiver_reason        text;
  v_reason_code          text;
  v_initiation_type      text;
  v_eligible_for_rehire  boolean;
  v_regrettable          boolean;
  v_comments             text;
  v_template_id          uuid;
  v_template_code        text;
  v_has_workflow         boolean := false;
  v_termination_id       uuid;
  v_instance_id          uuid;
  v_direct_reports_json  jsonb := '[]'::jsonb;
  v_default_mgr_id       uuid;
  v_default_mgr_name     text;
BEGIN
  -- ── 1. Resolve reason code ────────────────────────────────────────────────
  SELECT code INTO v_reason_code
  FROM   termination_reason_codes
  WHERE  code = p_reason_code AND is_active = true;

  IF v_reason_code IS NULL THEN
    RAISE EXCEPTION 'Invalid or inactive termination reason code: %', p_reason_code;
  END IF;

  -- ── 2. Derive initiation type ─────────────────────────────────────────────
  v_initiation_type := UPPER(COALESCE(p_initiation_type, 'HR'));
  IF v_initiation_type NOT IN ('SELF','HR','MANAGER') THEN
    RAISE EXCEPTION 'Invalid initiation type: %', v_initiation_type;
  END IF;

  -- ── 3. Notice period & dates ──────────────────────────────────────────────
  v_waived := COALESCE(p_notice_period_waiver, false);
  v_waiver_reason := CASE WHEN v_waived THEN p_waiver_reason ELSE NULL END;

  SELECT COALESCE(notice_period_days, 0)
  INTO   v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id = p_employee_id
    AND  effective_from <= p_separation_date
  AND  effective_to  >  p_separation_date
  AND  is_active     = true
  LIMIT  1;

  v_notice_period_days   := COALESCE(v_notice_period_days, 0);
  v_notice_expiry_date   := p_separation_date + v_notice_period_days;
  v_last_working_date    := CASE
                              WHEN v_waived THEN p_separation_date
                              ELSE v_notice_expiry_date
                            END;

  v_eligible_for_rehire  := COALESCE(p_eligible_for_rehire, true);
  v_regrettable          := COALESCE(p_regrettable, false);
  v_comments             := COALESCE(p_comment, p_comments);

  -- ── 4. Auto-populate direct reports when none supplied ───────────────────
  --    Default new manager = the terminating employee's own manager (grandparent)
  IF COALESCE(jsonb_array_length(p_reassignments), 0) = 0 THEN
    -- Grandparent: who does the terminating employee report to?
    SELECT ej2.manager_id,
           COALESCE(ep2.name, mgr.name)
    INTO   v_default_mgr_id, v_default_mgr_name
    FROM   employee_employment ej2
    JOIN   employees mgr ON mgr.id = ej2.manager_id
    LEFT JOIN employee_personal_info ep2
           ON ep2.employee_id = mgr.id AND ep2.effective_to = '9999-12-31'::date AND ep2.is_active = true
    WHERE  ej2.employee_id = p_employee_id
      AND  ej2.effective_from <= p_separation_date
      AND  ej2.effective_to  >  p_separation_date
      AND  ej2.is_active     = true
    LIMIT  1;

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'employee_id',      dr.id,
          'employee_name',    COALESCE(ep.name, dr.name),
          'new_manager_id',   v_default_mgr_id,
          'new_manager_name', v_default_mgr_name
        )
      ),
      '[]'::jsonb
    )
    INTO v_direct_reports_json
    FROM employee_employment ej
    JOIN employees dr ON dr.id = ej.employee_id
    LEFT JOIN employee_personal_info ep
           ON ep.employee_id = dr.id AND ep.effective_to = '9999-12-31'::date AND ep.is_active = true
    WHERE  ej.manager_id = p_employee_id
      AND  ej.effective_from <= p_separation_date
      AND  ej.effective_to  >  p_separation_date
      AND  ej.is_active     = true
      AND  dr.is_active     = true;
  ELSE
    v_direct_reports_json := p_reassignments;
  END IF;

  -- ── 5. Resolve workflow template ──────────────────────────────────────────
  SELECT wt.id, wt.code, true
  INTO   v_template_id, v_template_code, v_has_workflow
  FROM   workflow_template_assignments wta
  JOIN   workflow_templates wt ON wt.id = wta.template_id
  WHERE  wta.module_code = 'termination'
    AND  wta.is_active   = true
  LIMIT  1;

  -- ── 6. Insert termination record ─────────────────────────────────────────
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
    p_separation_date,
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
    v_direct_reports_json,
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 7. Workflow path vs direct-save path ─────────────────────────────────
  IF v_has_workflow THEN
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_termination_id,
      p_metadata      => jsonb_build_object(
                           'employee_id',       p_employee_id,
                           'initiation_type',   v_initiation_type,
                           'separation_date',   p_separation_date,
                           'reason_code',       v_reason_code
                         ),
      p_comment       => v_comments
    );

    UPDATE employee_terminations
    SET    workflow_status = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_by = auth.uid()
    WHERE  id = v_termination_id;

    RETURN jsonb_build_object(
      'termination_id', v_termination_id,
      'instance_id',    v_instance_id,
      'status',         'PENDING'
    );
  ELSE
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED',
           updated_by = auth.uid()
    WHERE  id = v_termination_id;

    RETURN jsonb_build_object(
      'termination_id', v_termination_id,
      'instance_id',    NULL,
      'status',         'APPROVED'
    );
  END IF;
END;
$fn$;


-- =============================================================================
-- END OF MIGRATION 551
-- =============================================================================
