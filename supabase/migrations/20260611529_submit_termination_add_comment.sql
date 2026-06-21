-- Migration 529: Add p_comment to submit_termination
--
-- Adds an optional p_comment parameter (forwarded to wf_submit → action_log.notes)
-- so the WorkflowSubmitModal comment field appears in the workflow timeline.
-- No schema changes. Backwards-compatible (existing callers without p_comment work).

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]',
  p_comment          text  DEFAULT NULL
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

  -- Notice period (computed, never from payload)
  v_notice_period_days        integer;
  v_notice_expiry_date        date;
  v_required_lwd              date;

  -- Picklist validation
  v_picklist_code             text;
  v_reason_valid              boolean;

  -- Workflow resolution
  v_template_id               uuid;
  v_template_code             text;
  v_has_workflow              boolean;

  -- Result
  v_termination_id            uuid;
  v_instance_id               uuid;
  v_att                       jsonb;
BEGIN

  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', p_employee_id)
    OR user_can('termination', 'edit', NULL)
    OR get_my_employee_id() = p_employee_id
    OR EXISTS (
         SELECT 1 FROM employees
         WHERE  id         = p_employee_id
           AND  manager_id = get_my_employee_id()
           AND  deleted_at IS NULL
       )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 2. Extract payload ─────────────────────────────────────────────────────
  v_separation_date     := NULLIF(p_termination_data->>'separation_date', '')::date;
  v_reason_code         := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_last_working_date   := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Required field validation ───────────────────────────────────────────
  IF v_separation_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'separation_date is required.');
  END IF;
  IF v_reason_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_reason_code is required.');
  END IF;
  IF v_comments IS NULL OR length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;
  IF v_reason_code = 'OTHER' AND length(v_comments) < 50 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'comments must be at least 50 characters when reason is OTHER.');
  END IF;

  -- ── 4. Derive initiation type ──────────────────────────────────────────────
  BEGIN
    v_initiation_type := derive_termination_initiation_type(p_employee_id, false);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: cannot initiate termination for this employee.');
  END;

  -- ── 5. Picklist validation ─────────────────────────────────────────────────
  v_picklist_code := CASE
    WHEN v_initiation_type = 'SELF' THEN 'RESIGNATION_REASON'
    ELSE 'TERMINATION_REASON'
  END;

  SELECT EXISTS (
    SELECT 1
    FROM   picklist_values pv
    JOIN   picklists pl ON pl.id = pv.picklist_id
    WHERE  pl.picklist_id = v_picklist_code
      AND  pv.ref_id      = v_reason_code
      AND  pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('termination_reason_code %s is not valid for picklist %s.',
             v_reason_code, v_picklist_code));
  END IF;

  -- ── 6. Read notice_period_days from employment ─────────────────────────────
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id    = p_employee_id
    AND  effective_from <= v_separation_date
    AND  effective_to   >  v_separation_date
    AND  is_active      = true
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF v_notice_period_days IS NULL THEN
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    LIMIT  1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active employment record found covering the separation date.');
  END IF;

  -- ── 7. Compute notice_expiry_date ──────────────────────────────────────────
  v_notice_expiry_date := CURRENT_DATE + v_notice_period_days;

  -- ── 8. SELF: separation_date must be on or after notice_expiry_date ─────────
  IF v_initiation_type = 'SELF' THEN
    IF v_separation_date < v_notice_expiry_date THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('separation_date must be on or after %s (today + %s notice days).',
               v_notice_expiry_date, v_notice_period_days));
    END IF;
  END IF;

  -- ── 9. Default last_working_date to separation_date if not provided ─────────
  IF v_last_working_date IS NULL THEN
    v_last_working_date := v_separation_date;
  END IF;

  -- ── 10. Notice period waiver check ─────────────────────────────────────────
  v_required_lwd := v_notice_expiry_date;

  IF v_last_working_date < v_required_lwd THEN
    IF v_initiation_type = 'SELF' THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('last_working_date cannot be before %s (notice expiry date). '
               || 'Employees cannot waive their own notice period.',
               v_required_lwd));
    ELSE
      v_waived := true;
      IF v_waiver_reason IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('notice_period_waiver_reason is required: '
                 || 'last_working_date is before notice expiry date (%s).',
                 v_required_lwd));
      END IF;
    END IF;
  END IF;

  -- ── 11. Strip HR-only fields from SELF ────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    v_eligible_for_rehire := true;
    v_regrettable         := NULL;
  END IF;

  -- ── 12. Resolve workflow assignment ───────────────────────────────────────
  v_template_id  := resolve_workflow_for_submission('termination', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 13. Insert DRAFT row ───────────────────────────────────────────────────
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
    'DRAFT',
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 14. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    -- p_comment forwarded so the submission note appears in the timeline.
    v_instance_id := wf_submit(
      p_template_code       => v_template_code,
      p_module_code         => 'termination',
      p_record_id           => v_termination_id,
      p_metadata            => jsonb_build_object(
        'employee_id',     p_employee_id,
        'separation_date', v_separation_date,
        'initiation_type', v_initiation_type
      ),
      p_comment             => NULLIF(trim(p_comment), ''),
      p_subject_employee_id => p_employee_id
    );

    UPDATE employee_terminations
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_termination_id;

  ELSE
    -- No workflow: direct-save → APPROVED
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_termination_id;
  END IF;

  -- ── 15. Attachments ────────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      termination_id, file_name, original_file_name,
      file_path, file_size_bytes, mime_type, uploaded_by
    ) VALUES (
      v_termination_id,
      v_att->>'file_name',
      COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
      v_att->>'file_path',
      (v_att->>'file_size_bytes')::integer,
      v_att->>'mime_type',
      auth.uid()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                   true,
    'termination_id',       v_termination_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',      CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END,
    'notice_expiry_date',   v_notice_expiry_date,
    'notice_period_days',   v_notice_period_days
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb, text) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb, text) IS
  'Mig 529: adds p_comment (DEFAULT NULL) forwarded to wf_submit for timeline display.';
