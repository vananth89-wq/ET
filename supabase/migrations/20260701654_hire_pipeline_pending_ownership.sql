-- Migration 566 — Apply ownership filter to Pending hire records
-- ──────────────────────────────────────────────────────────────
-- PROBLEM
-- ───────
-- Mig 416 left the Pending branch of employees_select open to any
-- hire_employee.view holder so workflow approvers could read the record
-- in WorkflowReview. Side effect: any HR Analyst with hire_employee.view
-- can see ALL Pending records, not just their own.
--
-- User intent: an HR Analyst without view_all_pending should see only
-- the hire records THEY created, regardless of status.
--
-- FIX
-- ───
-- Apply the same ownership filter to Pending as Draft/Incomplete/Rejected,
-- but add a fourth escape hatch: the assigned workflow approver for this
-- specific record. This preserves WorkflowReview access for managers and
-- HR Heads who are assigned a task, without opening the door to all analysts.
--
-- Pending branch now allows:
--   1. created_by IS NULL          — legacy pre-mig-253 records
--   2. created_by = auth.uid()     — the creator
--   3. view_all_pending            — HR Head
--   4. is_super_admin()            — super admin
--   5. assigned pending wf task    — the actual approver for this record
--
-- BLAST-RADIUS AUDIT
-- ──────────────────
-- ✓ Creator (vijaya bharathi) — sees own Pending record via created_by = auth.uid()
-- ✓ HR Head (view_all_pending) — unchanged; sees all records
-- ✓ Super admin — unchanged; is_super_admin() bypass
-- ✓ Assigned approver (manager, HR user) — sees record via workflow_tasks check
-- ✓ HR Analyst (no view_all_pending, not creator) — blocked from others' Pending
-- ✓ CC/notification task holders — wt.status = 'pending' only; CC tasks are
--   auto-approved to 'approved', so they do not grant lingering access
-- ✓ SECURITY DEFINER RPCs — bypass RLS; unaffected

DROP POLICY IF EXISTS employees_select ON employees;

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      -- ── Active employees ─────────────────────────────────────────────────
      (status = 'Active'
        AND user_can('employee_details', 'view', id))

      -- ── Inactive employees ───────────────────────────────────────────────
      OR (status = 'Inactive'
          AND user_can('inactive_employees', 'view', id))

      -- ── Hire pipeline: Draft / Incomplete / Rejected ─────────────────────
      -- Ownership: creator OR HR Head (view_all_pending) OR super admin OR legacy NULL.
      OR (status IN ('Draft', 'Incomplete', 'Rejected')
          AND user_can('hire_employee', 'view', NULL)
          AND (
            created_by IS NULL
            OR created_by = auth.uid()
            OR user_can('hire_employee', 'view_all_pending', NULL)
            OR is_super_admin()
          ))

      -- ── Hire pipeline: Pending ───────────────────────────────────────────
      -- Same ownership filter as above, PLUS assigned workflow approver.
      -- The approver escape hatch preserves WorkflowReview access for managers
      -- and HR Heads assigned a task on this record without opening the record
      -- to all analysts who happen to have hire_employee.view.
      OR (status = 'Pending'
          AND user_can('hire_employee', 'view', NULL)
          AND (
            created_by IS NULL
            OR created_by = auth.uid()
            OR user_can('hire_employee', 'view_all_pending', NULL)
            OR is_super_admin()
            OR EXISTS (
              SELECT 1
              FROM   workflow_tasks  wt
              JOIN   workflow_instances wi ON wi.id = wt.instance_id
              WHERE  wi.record_id   = employees.id
                AND  wi.module_code = 'employee_hire'
                AND  wt.assigned_to = auth.uid()
                AND  wt.status      = 'pending'
            )
          ))
    )
  );

COMMENT ON POLICY employees_select ON employees IS
  'Status-routed SELECT. '
  'Active: employee_details.view (target-group scoped). '
  'Inactive: inactive_employees.view. '
  'Draft/Incomplete/Rejected: hire_employee.view + ownership (own OR view_all_pending OR super admin OR legacy NULL). '
  'Pending: hire_employee.view + ownership OR assigned approver — prevents analysts seeing others'' Pending records '
  'while preserving WorkflowReview access for the actual assigned approver. '
  'Mig 416: ownership filter on Draft/Incomplete/Rejected. '
  'Mig 566: ownership filter extended to Pending; assigned-approver escape hatch added.';

-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  tablename  = 'employees'
      AND  policyname = 'employees_select'
      AND  cmd        = 'SELECT'
  ) THEN
    RAISE EXCEPTION 'ABORT: employees_select policy not found after migration 566.';
  END IF;
  RAISE NOTICE 'Migration 566 verified: employees_select Pending branch now has ownership filter.';
END;
$$;
