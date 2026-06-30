-- =============================================================================
-- Migration 629: submit_termination_reversal — fix subject_profile_id for
-- terminated employees
--
-- BUG
-- ───
-- wf_submit resolves subject_profile_id via:
--   SELECT id FROM profiles WHERE employee_id = p_subject_employee_id AND is_active = true
--
-- A terminated employee's profile has is_active = false, so the lookup returns
-- NULL and subject_profile_id falls back to submitted_by (the submitter).
-- Result: stalled banner and workflow list show the submitter name instead of
-- the terminated employee's name.
--
-- FIX
-- ───
-- After wf_submit returns the instance_id, directly UPDATE
-- workflow_instances.subject_profile_id using a lookup without is_active filter
-- (ORDER BY created_at DESC LIMIT 1 to get the most recent profile).
-- This overwrites whatever wf_submit may have set.
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
  v_termination       employee_terminations%ROWTYPE;
  v_reversal_reason   text;
  v_comments          text;
  v_reversal_id       uuid;
  v_instance_id       uuid;
  v_template_id       uuid;
  v_template_code     text;
  v_has_workflow      boolean;
  v_att               jsonb;
  v_employee_name     text;
  v_subject_profile   uuid;
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
  v_template_id  := resolve_workflow_for_submission('termination_reversal', auth.uid());
  v_has_workflow := v_template_id IS NOT NULL;

  IF v_has_workflow THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ── 5. Look up employee name + profile (no is_active filter — employee
  --       is terminated so profile.is_active = false) ──────────────────────
  SELECT e.name INTO v_employee_name
  FROM   employees e
  WHERE  e.id = v_termination.employee_id;

  SELECT p.id INTO v_subject_profile
  FROM   profiles p
  WHERE  p.employee_id = v_termination.employee_id
  ORDER BY p.created_at DESC
  LIMIT  1;

  -- ── 6. Insert DRAFT reversal row ──────────────────────────────────────────
  INSERT INTO employee_termination_reversals (
    termination_id, reversal_reason, comments,
    workflow_status, created_by, updated_by
  ) VALUES (
    p_termination_id, v_reversal_reason, v_comments,
    'DRAFT', auth.uid(), auth.uid()
  )
  RETURNING id INTO v_reversal_id;

  -- ── 7. Workflow path vs direct-save path ──────────────────────────────────
  IF v_has_workflow THEN
    v_instance_id := wf_submit(
      p_template_code       => v_template_code,
      p_module_code         => 'termination_reversal',
      p_record_id           => v_reversal_id,
      p_subject_employee_id => v_termination.employee_id,
      p_metadata            => jsonb_build_object(
        'employee_id',     v_termination.employee_id,
        'employee_name',   v_employee_name,
        'termination_id',  p_termination_id,
        'reversal_reason', v_reversal_reason
      )
    );

    -- ── Patch subject_profile_id: wf_submit's is_active=true lookup returns
    --    NULL for terminated employees; overwrite with the correct profile. ──
    IF v_subject_profile IS NOT NULL AND v_instance_id IS NOT NULL THEN
      UPDATE workflow_instances
      SET    subject_profile_id = v_subject_profile
      WHERE  id = v_instance_id;
    END IF;

    UPDATE employee_termination_reversals
    SET    workflow_status      = 'PENDING',
           workflow_instance_id = v_instance_id,
           updated_at           = NOW(),
           updated_by           = auth.uid()
    WHERE  id = v_reversal_id;

  ELSE
    -- No workflow assigned → direct-save: auto-APPROVED.
    UPDATE employee_termination_reversals
    SET    workflow_status = 'APPROVED',
           approved_at    = NOW(),
           approved_by    = auth.uid(),
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = v_reversal_id;

    UPDATE employee_terminations
    SET    workflow_status = 'REVERSED',
           updated_at     = NOW(),
           updated_by     = auth.uid()
    WHERE  id = p_termination_id;
  END IF;

  -- ── 8. Attachments ────────────────────────────────────────────────────────
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
  'Mig 629: after wf_submit, directly patches workflow_instances.subject_profile_id '
  'using a profiles lookup without is_active filter. Terminated employees have '
  'is_active=false so wf_submit''s own lookup returns NULL and falls back to the '
  'submitter. This patch ensures the stalled banner and workflow list show the '
  'terminated employee name, not the submitter.';
