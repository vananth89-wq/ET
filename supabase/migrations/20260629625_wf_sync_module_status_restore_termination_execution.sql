-- =============================================================================
-- Migration 625: wf_sync_module_status — restore inline termination execution
--
-- PROBLEM
-- ───────
-- Mig 611 (file 20260629611) did a CREATE OR REPLACE to add RAISE LOG for the
-- hire path, but used a version that dropped the inline execution block that
-- mig 608 introduced for terminations and reversals:
--
--   • Termination approved: fn_pre_insert + fn_finalize were no longer called
--     → scheduled_executed never set → "Re-run Finalization" button always shown
--   • Reversal approved: fn_revert was no longer called
--     → employment slices never restored → employee stays Inactive after reversal
--
-- FIX
-- ───
-- Restore the full wf_sync_module_status with:
--   1. Hire path: RAISE LOG (from mig 611) — preserved
--   2. Termination approved: inline fn_pre_insert + fn_finalize (from mig 608)
--   3. Reversal approved: inline fn_revert (from mig 608)
--      Both wrapped in inner BEGIN/EXCEPTION so a slice error doesn't roll back
--      the status UPDATEs.
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

  -- ── Termination (terminations + reversals share this module_code) ──────────
  ELSIF p_module_code = 'termination' THEN

    IF EXISTS (SELECT 1 FROM employee_terminations WHERE id = p_record_id) THEN

      IF p_status = 'approved' THEN
        UPDATE employee_terminations
        SET    workflow_status = 'APPROVED',
               approved_at    = now(),
               approved_by    = auth.uid(),
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;

        -- ── Inline Phase 1: close Active slice + insert Inactive marker ────────
        BEGIN
          PERFORM fn_pre_insert_termination_slices(p_record_id);
          RAISE LOG 'wf_sync_module_status: fn_pre_insert completed for termination %', p_record_id;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'wf_sync_module_status: fn_pre_insert failed for % — % (Re-run button will appear)',
                        p_record_id, SQLERRM;
        END;

        -- ── Inline Phase 2: finalize if LWD is today or past ─────────────────
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

    ELSIF EXISTS (SELECT 1 FROM employee_termination_reversals WHERE id = p_record_id) THEN

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

        -- ── Inline reversal execution: revert employment slices ───────────────
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
          'wf_sync_module_status: unhandled status % for reversal record % — unchanged',
          p_status, p_record_id;
      END IF;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: termination record % not found in either table — skipping',
        p_record_id;
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
  'and reversal execution (fn_revert) that mig 611 accidentally dropped when it '
  'added hire activation logging. Both execution blocks are wrapped in '
  'BEGIN/EXCEPTION so slice errors do not roll back the status UPDATEs.';
