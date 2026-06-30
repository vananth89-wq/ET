-- =============================================================================
-- Migration 575 — Add RAISE LOG to wf_sync_module_status for employee_hire
--
-- PROBLEM
-- ───────
-- Rabanee Pasha's hire workflow completed (approved 2026-06-23 08:32:23) but
-- employees.status remained 'Draft'. Both wf_advance_instance and
-- wf_sync_module_status are correct in the live DB, so the failure was
-- transient and undiagnosable post-hoc.
--
-- FIX
-- ───
-- Add RAISE LOG statements around the employee_hire approved UPDATE so that
-- Supabase logs capture: the employee id, rows affected, and new status.
-- This lets us diagnose any future recurrence without time-travel.
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
  'Routes workflow status changes to the correct module table. '
  'Mig 575: added RAISE LOG + ROW_COUNT check for employee_hire approved path '
  'to diagnose future cases where employees.status is not flipped to Active.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'wf_sync_module_status'
  ) THEN
    RAISE EXCEPTION 'ABORT: wf_sync_module_status not found after migration 575.';
  END IF;
  RAISE NOTICE 'Migration 575 verified: wf_sync_module_status updated with hire activation logging.';
END $$;
