-- =============================================================================
-- Migration 066: Fix line_items_update — add approver clause
--
-- Gap identified after migration 064:
--   The line_items_update policy only allowed admin and expense.edit holders
--   (ESS employees editing their own draft reports).  Approvers who need to
--   add/edit notes on submitted reports were silently blocked by RLS —
--   their UPDATE calls returned 0 rows affected.
--
-- Fix:
--   Rebuild line_items_update to also permit holders of expense.edit_approval
--   who are the current workflow assignee on the parent report.
--   Uses is_workflow_assignee() (created in migration 064) to avoid the
--   circular-RLS-recursion that inline subqueries on workflow_tasks cause.
--
-- Impact analysis:
--   • ESS edit path (expense.edit + draft + own report) — UNCHANGED
--   • Admin path — UNCHANGED
--   • New approver path — additive only, scoped strictly to is_workflow_assignee
--   • No other tables or policies are touched
-- =============================================================================


DROP POLICY IF EXISTS line_items_update ON line_items;

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    -- ESS: own draft reports
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1
          FROM   expense_reports er
          WHERE  er.id          = line_items.report_id
            AND  er.status      = 'draft'
            AND  er.employee_id = get_my_employee_id()
        ))
    -- Approver: current workflow assignee on the parent report
    OR (has_permission('expense.edit_approval')
        AND is_workflow_assignee(line_items.report_id, 'expense_reports'))
  )
  WITH CHECK (
    has_role('admin')
    -- ESS: own draft reports
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1
          FROM   expense_reports er
          WHERE  er.id          = line_items.report_id
            AND  er.status      = 'draft'
            AND  er.employee_id = get_my_employee_id()
        ))
    -- Approver: current workflow assignee on the parent report
    OR (has_permission('expense.edit_approval')
        AND is_workflow_assignee(line_items.report_id, 'expense_reports'))
  );

COMMENT ON POLICY line_items_update ON line_items IS
  'Allows UPDATE to: admins (all), employees with expense.edit on own draft '
  'reports, and approvers with expense.edit_approval who are the active '
  'workflow assignee (via is_workflow_assignee — SECURITY DEFINER, no recursion).';


-- VERIFICATION
SELECT policyname, cmd, qual, with_check
FROM   pg_policies
WHERE  tablename = 'line_items'
  AND  policyname = 'line_items_update';
