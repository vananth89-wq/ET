-- =============================================================================
-- Migration 492 — Termination: workflow resolution via resolve_workflow_for_submission
--
-- PROBLEM
-- ───────
-- Mig 489/491 hardcoded template codes ('termination_self', 'termination_hr',
-- 'termination_manager', 'termination_reversal') and always called wf_submit,
-- which would fail with "no template found" if the admin hadn't configured
-- workflow assignments.
--
-- CORRECT PATTERN (per personal_info / employment / all other modules)
-- ────────────────────────────────────────────────────────────────────
-- Use resolve_workflow_for_submission('termination', auth.uid()):
--   • Returns a template_id → workflow path: wf_submit → workflow_status='PENDING'
--   • Returns NULL         → direct path:   skip wf_submit → workflow_status='APPROVED'
--                            scheduled_executed=false so the daily Edge Function
--                            (process_scheduled_terminations) picks it up.
--
-- The admin configures which workflow template applies via the Workflow →
-- Assignments UI. The initiation type is stored for audit and UI display
-- but does NOT drive template selection — the assignment configuration does.
--
-- Changes:
--   1. Replace submit_termination   (mig 491 version)
--   2. Replace submit_termination_reversal (mig 489 version)
--
-- Predecessor: 20260604491
-- Next: 20260604493 (Phase 3 — workflow integration)
-- =============================================================================


-- =============================================================================
-- 1. submit_termination — workflow resolution via resolve_workflow_for_submission
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination(
  p_employee_id      uuid,
  p_termination_data jsonb,
  p_attachments      jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Initiation
  v_initiation_type       text;

  -- Payload fields
  v_termination_date      date;
  v_reason_code           text;
  v_resignation_date      date;
  v_notice_date           date;
  v_last_working_date     date;
  v_waived                boolean;
  v_waiver_reason         text;
  v_eligible_for_rehire   boolean;
  v_regrettable           boolean;
  v_comments              text;

  -- Notice period
  v_notice_period_days    integer;
  v_required_lwd          date;

  -- Picklist validation
  v_picklist_code         text;
  v_reason_valid          boolean;

  -- Workflow resolution
  v_template_id           uuid;
  v_template_code         text;
  v_has_workflow          boolean;

  -- Result
  v_termination_id        uuid;
  v_instance_id           uuid;

  v_att                   jsonb;
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
  v_termination_date    := NULLIF(p_termination_data->>'termination_date', '')::date;
  v_reason_code         := NULLIF(p_termination_data->>'termination_reason_code', '');
  v_resignation_date    := NULLIF(p_termination_data->>'resignation_date', '')::date;
  v_notice_date         := NULLIF(p_termination_data->>'notice_date', '')::date;
  v_last_working_date   := NULLIF(p_termination_data->>'last_working_date', '')::date;
  v_waived              := COALESCE((p_termination_data->>'notice_period_waived')::boolean, false);
  v_waiver_reason       := NULLIF(p_termination_data->>'notice_period_waiver_reason', '');
  v_eligible_for_rehire := COALESCE((p_termination_data->>'eligible_for_rehire')::boolean, true);
  v_regrettable         := (p_termination_data->>'regrettable_termination')::boolean;
  v_comments            := NULLIF(p_termination_data->>'comments', '');

  -- ── 3. Required field validation ───────────────────────────────────────────
  IF v_termination_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'termination_date is required.');
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

  -- ── 5. Picklist validation (§1 decision #11) ───────────────────────────────
  v_picklist_code := CASE
    WHEN v_initiation_type = 'SELF' THEN 'RESIGNATION_REASON'
    ELSE 'TERMINATION_REASON'
  END;

  SELECT EXISTS (
    SELECT 1 FROM picklist_values pv
    JOIN picklists pl ON pl.id = pv.picklist_id
    WHERE pl.picklist_id = v_picklist_code
      AND pv.ref_id      = v_reason_code
      AND pv.active      = true
  ) INTO v_reason_valid;

  IF NOT v_reason_valid THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('termination_reason_code %s is not valid for picklist %s.',
             v_reason_code, v_picklist_code));
  END IF;

  -- ── 6. SELF-specific validations ───────────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    IF v_resignation_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'resignation_date is required for self-service termination.');
    END IF;
    IF v_last_working_date IS NOT NULL AND v_last_working_date < v_resignation_date THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'last_working_date must be on or after resignation_date.');
    END IF;
  END IF;

  -- ── 7. Read notice_period_days from the covering employment slice ──────────
  SELECT notice_period_days INTO v_notice_period_days
  FROM   employee_employment
  WHERE  employee_id    = p_employee_id
    AND  effective_from <= v_termination_date
    AND  effective_to   >  v_termination_date
    AND  is_active      = true
  ORDER BY effective_from DESC
  LIMIT 1;

  -- Fallback: open-ended current slice
  IF v_notice_period_days IS NULL THEN
    SELECT notice_period_days INTO v_notice_period_days
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    LIMIT 1;
  END IF;

  IF v_notice_period_days IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active employment record found covering the termination date.');
  END IF;

  -- ── 8. Notice period enforcement ──────────────────────────────────────────
  IF v_initiation_type = 'SELF' AND v_last_working_date IS NOT NULL THEN
    v_required_lwd := v_resignation_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('last_working_date must be on or after %s (resignation_date + %s notice days).',
               v_required_lwd, v_notice_period_days));
    END IF;
  ELSIF v_initiation_type <> 'SELF' AND v_last_working_date IS NOT NULL THEN
    v_required_lwd := v_termination_date + v_notice_period_days;
    IF v_last_working_date < v_required_lwd THEN
      v_waived := true;
      IF v_waiver_reason IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('notice_period_waiver_reason is required: last_working_date is before %s.',
                 v_required_lwd));
      END IF;
    END IF;
  END IF;

  -- ── 9. Strip HR-only fields from SELF ─────────────────────────────────────
  IF v_initiation_type = 'SELF' THEN
    v_eligible_for_rehire := true;
    v_regrettable         := NULL;
  END IF;

  -- ── 10. Resolve workflow assignment ───────────────────────────────────────
  -- Uses the same resolve_workflow_for_submission pattern as all other modules.
  -- Admin configures the assignment in Workflow → Assignments UI.
  -- NULL = no assignment configured → direct-save path.
  v_template_id  := resolve_workflow_for_submission('termination', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 11. Insert DRAFT row ───────────────────────────────────────────────────
  INSERT INTO employee_terminations (
    employee_id, termination_date, termination_reason_code,
    termination_initiation_type, resignation_date, notice_date, last_working_date,
    notice_period_waived, notice_period_waiver_reason,
    eligible_for_rehire, regrettable_termination, comments,
    workflow_status, created_by, updated_by
  ) VALUES (
    p_employee_id, v_termination_date, v_reason_code,
    v_initiation_type, v_resignation_date, v_notice_date, v_last_working_date,
    v_waived, v_waiver_reason, v_eligible_for_rehire, v_regrettable, v_comments,
    'DRAFT', auth.uid(), auth.uid()
  )
  RETURNING id INTO v_termination_id;

  -- ── 12. Workflow path vs direct-save path ─────────────────────────────────
  IF v_has_workflow THEN
    -- Workflow configured: submit to approval queue → PENDING
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_termination_id,
      p_metadata      => jsonb_build_object(
        'employee_id',     p_employee_id,
        'termination_date', v_termination_date,
        'initiation_type', v_initiation_type
      )
    );

    UPDATE employee_terminations
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_termination_id;

  ELSE
    -- No workflow assigned: direct-save → APPROVED immediately.
    -- Post-approval automation (employment slice closure, employees.status flip)
    -- is handled by the process_scheduled_terminations Edge Function (daily cron,
    -- Phase 4). For same-day / past-dated terminations the cron fires overnight;
    -- HR can also trigger apply_termination_approval manually via the Edge Function.
    UPDATE employee_terminations
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_termination_id;
  END IF;

  -- ── 13. Attachments ────────────────────────────────────────────────────────
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
    'workflow_status',      CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination(uuid, jsonb, jsonb) IS
  'Mig 489: initial. Mig 491: MANAGER_INITIATED added. '
  'Mig 492: workflow resolved via resolve_workflow_for_submission (not hardcoded template codes). '
  'No assignment configured → direct-save to APPROVED; scheduled_executed=false so the '
  'daily process_scheduled_terminations Edge Function applies the employment changes.';


-- =============================================================================
-- 2. submit_termination_reversal — same workflow-resolution pattern
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_termination_reversal(
  p_termination_id  uuid,
  p_reversal_data   jsonb,
  p_attachments     jsonb DEFAULT '[]'
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination     employee_terminations%ROWTYPE;
  v_reversal_reason text;
  v_comments        text;
  v_reversal_id     uuid;
  v_instance_id     uuid;
  v_template_id     uuid;
  v_template_code   text;
  v_has_workflow    boolean;
  v_att             jsonb;
BEGIN

  -- ── 1. Load and validate original termination ──────────────────────────────
  SELECT * INTO v_termination
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found.');
  END IF;

  IF v_termination.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Only APPROVED terminations can be reversed. Current status: '
      || v_termination.workflow_status || '.');
  END IF;

  -- ── 2. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', v_termination.employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 3. Validate payload ────────────────────────────────────────────────────
  v_reversal_reason := NULLIF(p_reversal_data->>'reversal_reason', '');
  v_comments        := NULLIF(p_reversal_data->>'comments', '');

  IF v_reversal_reason IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reversal_reason is required.');
  END IF;
  IF v_comments IS NULL OR length(v_comments) < 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'comments must be at least 20 characters.');
  END IF;

  -- ── 4. Resolve workflow assignment ────────────────────────────────────────
  v_template_id  := resolve_workflow_for_submission('termination', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 5. Insert DRAFT reversal row ──────────────────────────────────────────
  INSERT INTO employee_termination_reversals (
    termination_id, reversal_reason, comments,
    workflow_status, created_by, updated_by
  ) VALUES (
    p_termination_id, v_reversal_reason, v_comments,
    'DRAFT', auth.uid(), auth.uid()
  )
  RETURNING id INTO v_reversal_id;

  -- ── 6. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    v_instance_id := wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'termination',
      p_record_id     => v_reversal_id,
      p_metadata      => jsonb_build_object(
        'employee_id',    v_termination.employee_id,
        'termination_id', p_termination_id,
        'reversal_reason', v_reversal_reason
      )
    );

    UPDATE employee_termination_reversals
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_reversal_id;

  ELSE
    -- Direct-save: APPROVED immediately.
    -- apply_termination_reversal Edge Function (Phase 4) handles the
    -- slice reopening + employees.status flip.
    UPDATE employee_termination_reversals
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_reversal_id;

    -- Also mark the original termination as REVERSED (unlocks partial unique index)
    UPDATE employee_terminations
    SET    workflow_status = 'REVERSED',
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = p_termination_id;
  END IF;

  -- ── 7. Attachments ────────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_termination_attachments (
      reversal_id, file_name, original_file_name,
      file_path, file_size_bytes, mime_type, uploaded_by
    ) VALUES (
      v_reversal_id,
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
    'reversal_id',          v_reversal_id,
    'workflow_instance_id', v_instance_id,
    'workflow_status',      CASE WHEN v_has_workflow THEN 'PENDING' ELSE 'APPROVED' END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION submit_termination_reversal(uuid, jsonb, jsonb) IS
  'Mig 489: initial. '
  'Mig 492: workflow resolved via resolve_workflow_for_submission. '
  'No assignment → direct-save to APPROVED; original termination flipped to REVERSED inline. '
  'Employment slice restoration handled by apply_termination_reversal Edge Function (Phase 4).';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT proname,
       prosrc LIKE '%resolve_workflow_for_submission%' AS uses_resolver,
       prosrc NOT LIKE '%termination_self%'            AS no_hardcoded_templates
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('submit_termination', 'submit_termination_reversal');
-- Expect: both rows have uses_resolver=true, no_hardcoded_templates=true

-- =============================================================================
-- END OF MIGRATION 492
-- =============================================================================
