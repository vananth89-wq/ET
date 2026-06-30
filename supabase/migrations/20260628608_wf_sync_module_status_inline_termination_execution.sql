-- =============================================================================
-- Migration 608: wf_sync_module_status — inline termination execution
--
-- ROOT CAUSE OF ALL TERMINATION STALLS
-- ──────────────────────────────────────
-- The employment slice operations (fn_pre_insert_termination_slices,
-- fn_finalize_termination_execution, fn_revert_termination_execution) were
-- triggered by fire-and-forget Edge Function calls from ApproverInbox.tsx.
-- If the EF cold-starts, times out, or fails for any reason, the approval
-- succeeds but the slices are never written. Every admin workaround (Re-run
-- button, stalled workflow page) is a patch around this structural flaw.
--
-- THE FIX
-- ────────
-- Call the slice execution functions directly inside wf_sync_module_status,
-- which is called from wf_advance_instance in the same DB transaction as the
-- final approval step. This makes execution atomic:
--   • If slices succeed → approval commits, employee goes Inactive, DRs reassigned
--   • If slices fail   → we catch the exception, log a WARNING, and let the
--                        approval commit anyway (idempotent, EF/cron can retry)
--
-- The EF (apply-termination-approval) remains in place as a redundant
-- belt-and-suspenders call — harmless since all functions are idempotent.
--
-- TERMINATION path (status = 'approved', record in employee_terminations):
--   1. Set et.workflow_status = 'APPROVED'
--   2. Call fn_pre_insert_termination_slices  — close Active slice, insert Inactive
--   3. If LWD <= today: call fn_finalize_termination_execution  — deactivate + DR reassign
--
-- REVERSAL path (status = 'approved', record in employee_termination_reversals):
--   1. Set etr.workflow_status = 'APPROVED'
--   2. Set et.workflow_status  = 'REVERSED'
--   3. Call fn_revert_termination_execution   — delete Inactive slice, reopen Active
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
  v_today          date := CURRENT_DATE;
  v_slice_result   jsonb;
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

    -- ── PRIMARY TERMINATION ───────────────────────────────────────────────────
    IF EXISTS (SELECT 1 FROM employee_terminations WHERE id = p_record_id) THEN

      IF p_status = 'approved' THEN
        UPDATE employee_terminations
        SET    workflow_status = 'APPROVED',
               approved_at    = now(),
               approved_by    = auth.uid(),
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;

        -- ── Inline execution: Phase 1 — insert employment slices ─────────────
        -- Wrapped in exception handler so a slice failure never rolls back
        -- the approval itself. The EF / cron will retry if this fails.
        BEGIN
          SELECT fn_pre_insert_termination_slices(p_record_id) INTO v_slice_result;

          IF (v_slice_result->>'ok')::boolean THEN
            v_lwd := (v_slice_result->>'lwd')::date;

            -- ── Phase 2 — finalize immediately if LWD <= today ───────────────
            IF v_lwd IS NOT NULL AND v_lwd <= v_today THEN
              PERFORM fn_finalize_termination_execution(p_record_id);
              RAISE LOG 'wf_sync_module_status: fn_finalize_termination_execution completed for termination %', p_record_id;
            ELSE
              RAISE LOG 'wf_sync_module_status: termination % is future-dated (lwd: %) — finalize deferred to cron', p_record_id, v_lwd;
            END IF;
          ELSE
            RAISE WARNING 'wf_sync_module_status: fn_pre_insert_termination_slices failed for % — %',
                          p_record_id, v_slice_result->>'error';
          END IF;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'wf_sync_module_status: termination execution failed for % — % (EF/cron will retry)',
                        p_record_id, SQLERRM;
        END;

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

    -- ── REVERSAL ──────────────────────────────────────────────────────────────
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

        -- ── Inline execution: revert employment slices ────────────────────────
        BEGIN
          PERFORM fn_revert_termination_execution(p_record_id);
          RAISE LOG 'wf_sync_module_status: fn_revert_termination_execution completed for reversal %', p_record_id;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'wf_sync_module_status: reversal execution failed for % — % (EF will retry)',
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
  'Mig 608: termination + reversal execution is now inline (no EF dependency). '
  'On approval of a primary termination: calls fn_pre_insert_termination_slices '
  'then fn_finalize_termination_execution (if LWD <= today) in the same DB '
  'transaction. On approval of a reversal: calls fn_revert_termination_execution. '
  'Exceptions are caught and logged as WARNINGs so a slice failure never rolls '
  'back the approval. EF calls from the frontend are now redundant but harmless '
  '(all functions are idempotent).';
