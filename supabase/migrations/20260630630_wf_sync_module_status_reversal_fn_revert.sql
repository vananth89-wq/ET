-- =============================================================================
-- Migration 630: wf_sync_module_status — add fn_revert call to
-- termination_reversal branch
--
-- BUG
-- ───
-- Mig 627 added the 'termination_reversal' ELSIF branch to wf_sync_module_status
-- but omitted the fn_revert_termination_execution call. As a result, when a
-- reversal workflow reaches final approval, the reversal and termination statuses
-- are updated (APPROVED / REVERSED) but the employment slices are never restored
-- — the employee stays Inactive.
--
-- FIX
-- ───
-- Add fn_revert_termination_execution call (wrapped in BEGIN/EXCEPTION) to the
-- 'approved' sub-branch of the 'termination_reversal' ELSIF, identical to how
-- mig 625 handled it in the old 'termination' reversal sub-branch.
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

      BEGIN
        PERFORM fn_pre_insert_termination_slices(p_record_id);
        RAISE LOG 'wf_sync_module_status: fn_pre_insert completed for termination %', p_record_id;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'wf_sync_module_status: fn_pre_insert failed for % — % (Re-run button will appear)',
                      p_record_id, SQLERRM;
      END;

      SELECT COALESCE(last_working_date, separation_date)
      INTO   v_lwd
      FROM   employee_terminations
      WHERE  id = p_record_id;

      IF v_lwd IS NOT NULL AND v_lwd <= CURRENT_DATE THEN
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

      -- ── Inline reversal execution: revert employment slices ──────────────
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

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Mig 625: restores inline termination execution (fn_pre_insert + fn_finalize) '
  'and reversal execution (fn_revert). '
  'Mig 627: termination_reversal is now a separate module_code. '
  'Mig 630: adds fn_revert_termination_execution call to the termination_reversal '
  'approved branch — was missing from mig 627, causing employment slices to not '
  'be restored after reversal approval.';
