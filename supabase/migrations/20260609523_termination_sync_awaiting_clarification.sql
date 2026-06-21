-- Migration 523: Add awaiting_clarification branch to wf_sync_module_status
--               for the termination module.
--
-- Gap: when an approver clicks "Send Back", the workflow engine calls
-- wf_sync_module_status('termination', record_id, 'awaiting_clarification').
-- The termination branch had no handler for this status, so execution fell
-- through to RAISE NOTICE — a silent no-op.
--
-- Fix: add an explicit awaiting_clarification branch. The correct behaviour
-- is a no-op on employee_terminations (the record stays PENDING — it has not
-- been rejected or approved). The branch must exist so future status mappings
-- can be added without touching this file, and so the RAISE NOTICE is not
-- triggered spuriously in logs.
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
          WHEN 'awaiting_clarification' THEN 'pending'   -- sent back; stays pending
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
      UPDATE employees
      SET    status     = 'Active',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

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

      -- ── TERMINATION record ──────────────────────────────────────────────────
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
        -- No-op: record stays PENDING.
        -- submitted/in_progress: submit_termination already set PENDING.
        -- awaiting_clarification: approver sent back — record remains PENDING
        --   until the initiator amends and resubmits.
        NULL;

      ELSE
        RAISE NOTICE
          'wf_sync_module_status: unhandled status % for termination record % — unchanged',
          p_status, p_record_id;
      END IF;

    ELSIF EXISTS (SELECT 1 FROM employee_termination_reversals WHERE id = p_record_id) THEN

      -- ── REVERSAL record ────────────────────────────────────────────────────
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
        -- No-op: reversal stays PENDING.
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
  'Syncs module-side record status from workflow engine events. '
  'termination branch: awaiting_clarification is a no-op (record stays PENDING). '
  'Mig 523: added explicit awaiting_clarification handler for termination + reversal.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%awaiting_clarification%' AS has_clarification_branch
FROM   pg_proc
WHERE  proname = 'wf_sync_module_status';
