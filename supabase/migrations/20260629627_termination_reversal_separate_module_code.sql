-- =============================================================================
-- Migration 627: termination_reversal — distinct module_code
--
-- PROBLEM
-- ───────
-- submit_termination_reversal passed p_module_code => 'termination' to wf_submit,
-- so workflow_instances.module_code = 'termination' for both primary terminations
-- AND reversals.  The Workflow Operations MODULE column therefore showed
-- "Termination" for reversal workflows instead of "Termination Reversal".
--
-- FIX
-- ───
-- 1. wf_sync_module_status: add a dedicated ELSIF branch for 'termination_reversal'
--    that handles the reversal record directly (no table-sniff EXISTS check).
--    The 'termination' branch retains only the primary termination path.
--
-- 2. submit_termination_reversal: pass p_module_code => 'termination_reversal'
--    to wf_submit (was 'termination').  module_codes table already has this row.
--
-- 3. wf_submit: the concurrent-termination guard uses `IF p_module_code <> 'termination'`
--    which already excludes 'termination_reversal' (different string), so no change
--    needed — reversals are correctly NOT subject to the termination guard.
-- =============================================================================


-- =============================================================================
-- Part 1: wf_sync_module_status — separate termination_reversal branch
--   Base: mig 625 (full body).  Removes reversal sub-branch from 'termination',
--   adds new top-level ELSIF for 'termination_reversal'.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id    uuid;
  v_termination_id uuid;
  v_rows_affected  integer;
  v_lwd            date;
BEGIN

  -- ── Expense Reports ────────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles WHERE id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'              THEN 'pending'
          WHEN 'in_progress'            THEN 'pending'
          WHEN 'awaiting_clarification' THEN 'pending'
          WHEN 'draft'                  THEN 'withdrawn'
          WHEN 'cancelled'              THEN 'withdrawn'
          WHEN 'approved'               THEN 'approved'
          WHEN 'rejected'               THEN 'rejected'
          WHEN 'withdrawn'              THEN 'withdrawn'
          ELSE status
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Employee Hire ──────────────────────────────────────────────────────────
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status IN ('submitted', 'in_progress') THEN
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'approved' THEN
      RAISE LOG 'wf_sync_module_status: activating employee % (hire approved)', p_record_id;

      UPDATE employees
      SET    status     = 'Active',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

      GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
      RAISE LOG 'wf_sync_module_status: employee % activation UPDATE affected % row(s)',
                p_record_id, v_rows_affected;

      IF v_rows_affected = 0 THEN
        RAISE WARNING 'wf_sync_module_status: employee % NOT found or UPDATE matched 0 rows — status may be stuck at Draft',
                      p_record_id;
      END IF;

    ELSIF p_status = 'rejected' THEN
      UPDATE employees
      SET    status     = 'Rejected',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'awaiting_clarification' THEN
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'draft' THEN
      UPDATE employees
      SET    deleted_at = now(),
             updated_at = now()
      WHERE  id      = p_record_id
        AND  status != 'Active';

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for employee_hire — record unchanged',
        p_status;
    END IF;

  -- ── Primary Termination ────────────────────────────────────────────────────
  ELSIF p_module_code = 'termination' THEN

    IF p_status = 'approved' THEN
      UPDATE employee_terminations
      SET    workflow_status = 'APPROVED',
             approved_at    = now(),
             approved_by    = auth.uid(),
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

      -- ── Inline Phase 1: close Active slice + insert Inactive marker ─────────
      BEGIN
        PERFORM fn_pre_insert_termination_slices(p_record_id);
        RAISE LOG 'wf_sync_module_status: fn_pre_insert completed for termination %', p_record_id;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'wf_sync_module_status: fn_pre_insert failed for % — % (Re-run button will appear)',
                      p_record_id, SQLERRM;
      END;

      -- ── Inline Phase 2: finalize if LWD is today or past ──────────────────
      SELECT COALESCE(last_working_date, separation_date)
      INTO   v_lwd
      FROM   employee_terminations
      WHERE  id = p_record_id;

      IF v_lwd IS NOT NULL AND v_lwd < CURRENT_DATE THEN  -- < not <=: execute AFTER LWD, not on it
        BEGIN
          PERFORM fn_finalize_termination_execution(p_record_id);
          RAISE LOG 'wf_sync_module_status: fn_finalize completed for termination %', p_record_id;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'wf_sync_module_status: fn_finalize failed for % — % (Re-run button will appear)',
                        p_record_id, SQLERRM;
        END;
      END IF;

    ELSIF p_status = 'rejected' THEN
      UPDATE employee_terminations
      SET    workflow_status = 'REJECTED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
      UPDATE employee_terminations
      SET    workflow_status      = 'WITHDRAWN',
             workflow_instance_id = NULL,
             updated_at           = now(),
             updated_by           = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('submitted', 'in_progress', 'awaiting_clarification') THEN
      NULL;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for termination record % — unchanged',
        p_status, p_record_id;
    END IF;

  -- ── Termination Reversal ───────────────────────────────────────────────────
  ELSIF p_module_code = 'termination_reversal' THEN

    IF p_status = 'approved' THEN
      UPDATE employee_termination_reversals
      SET    workflow_status = 'APPROVED',
             approved_at    = now(),
             approved_by    = auth.uid(),
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

      UPDATE employee_terminations
      SET    workflow_status = 'REVERSED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = (
        SELECT termination_id
        FROM   employee_termination_reversals
        WHERE  id = p_record_id
      );

      -- ── Inline reversal execution: revert employment slices ─────────────────
      BEGIN
        PERFORM fn_revert_termination_execution(p_record_id);
        RAISE LOG 'wf_sync_module_status: fn_revert completed for reversal %', p_record_id;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'wf_sync_module_status: fn_revert failed for % — % (EF will retry)',
                      p_record_id, SQLERRM;
      END;

    ELSIF p_status = 'rejected' THEN
      UPDATE employee_termination_reversals
      SET    workflow_status = 'REJECTED',
             updated_at     = now(),
             updated_by     = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
      UPDATE employee_termination_reversals
      SET    workflow_status      = 'WITHDRAWN',
             workflow_instance_id = NULL,
             updated_at           = now(),
             updated_by           = auth.uid()
      WHERE  id = p_record_id;

    ELSIF p_status IN ('submitted', 'in_progress', 'awaiting_clarification') THEN
      NULL;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for termination_reversal record % — unchanged',
        p_status, p_record_id;
    END IF;

  -- ── Unknown module ─────────────────────────────────────────────────────────
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;

END;
$$;

REVOKE ALL     ON FUNCTION wf_sync_module_status(text, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_sync_module_status(text, uuid, text) TO authenticated;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Mig 625: restores inline termination execution (fn_pre_insert + fn_finalize) '
  'and reversal execution (fn_revert). '
  'Mig 627: termination_reversal is now a separate module_code — the reversal '
  'sub-branch has been removed from the termination ELSIF and promoted to its '
  'own top-level ELSIF p_module_code = ''termination_reversal'' branch.';


-- =============================================================================
-- Part 2: submit_termination_reversal — pass p_module_code => 'termination_reversal'
--   Base: mig 626 (full body).  Single change: 'termination' → 'termination_reversal'
--   in the wf_submit call.  Everything else identical.
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
  v_employee_name   text;
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

  -- ── 5. Look up employee name for metadata ─────────────────────────────────
  SELECT name INTO v_employee_name
  FROM   employees
  WHERE  id = v_termination.employee_id;

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
  'Mig 626: pass p_subject_employee_id to wf_submit so workflow_instances.'
  'subject_profile_id is set → get_stalled_workflows and participants modal '
  'show the terminated employee name instead of the submitter name. '
  'Mig 627: p_module_code changed from ''termination'' to ''termination_reversal'' '
  'so the Workflow Operations MODULE column shows "Termination Reversal".';
