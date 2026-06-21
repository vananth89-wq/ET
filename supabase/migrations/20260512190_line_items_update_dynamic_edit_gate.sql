-- =============================================================================
-- Migration 190: line_items_update — replace expense.edit_approval with
--                dynamic gate (expense.edit + is_workflow_assignee)
--
-- BACKGROUND
-- ──────────
-- The original design used a separate permission code 'expense.edit_approval'
-- to gate approver writes on line items during review. That code was seeded
-- into the old role_permissions table (migrations 007/008), which was dropped
-- in migration 146 when the RBP permission-set system became the sole source
-- of truth. The new RBP system never received the 'expense.edit_approval'
-- seed for Finance/Manager/Admin permission sets, so has_permission() always
-- returns false for approvers — silently blocking note saves in WorkflowReview.
--
-- DESIGN CHANGE
-- ─────────────
-- The product design was updated: if a user is the active workflow assignee
-- AND holds the standard 'expense.edit' permission, they are implicitly
-- allowed to edit line item data mid-flight when the step has allow_edit=true.
-- No separate 'expense.edit_approval' permission is required.
--
-- This matches migration 084's rbp_line_items_update policy, which already
-- implements the correct logic via user_can() + active-assignee + allow_edit.
-- This migration aligns the older non-rbp line_items_update policy to the
-- same approach so both policies are consistent.
--
-- CHANGES
-- ───────
-- Rebuild line_items_update (non-rbp, last set in migration 078):
--   Old approver path:
--     has_permission('expense.edit_approval')
--     AND is_workflow_assignee(line_items.report_id, 'expense_reports')
--
--   New approver path:
--     has_permission('expense.edit')
--     AND is_workflow_assignee(line_items.report_id, 'expense_reports')
--
-- ESS path (employee editing own draft/rejected/clarification) — UNCHANGED.
-- Admin path — UNCHANGED.
-- is_workflow_assignee() is SECURITY DEFINER (migration 064) — no recursion.
--
-- IMPACT
-- ──────
-- • Finance, Manager, Dept Head, HR, Admin — all have 'expense.edit' in their
--   permission sets → approver writes now permitted when they are the assignee.
-- • ESS users have 'expense.edit' only on their own draft reports (scoped by
--   get_my_employee_id() + status=draft/rejected/clarification) — the own-report
--   guard is unchanged, so ESS cannot write other people's submitted reports.
-- • 'expense.edit_approval' permission code is NOT removed — it still exists
--   in the permissions table and is still referenced by module_registry
--   (approval_write_permission) and can_write_module_record() Path 2. Those
--   code paths are unchanged.
-- =============================================================================


DROP POLICY IF EXISTS line_items_update ON line_items;

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    -- ESS: own draft / rejected / awaiting-clarification reports
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1
        FROM   expense_reports er
        WHERE  er.id          = line_items.report_id
          AND  er.employee_id = get_my_employee_id()
          AND  (
            er.status IN ('draft', 'rejected')
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
    -- Approver: active workflow assignee with standard edit permission
    OR (
      has_permission('expense.edit')
      AND is_workflow_assignee(line_items.report_id, 'expense_reports')
    )
  )
  WITH CHECK (
    has_role('admin')
    -- ESS: own draft / rejected / awaiting-clarification reports
    OR (
      has_permission('expense.edit')
      AND EXISTS (
        SELECT 1
        FROM   expense_reports er
        WHERE  er.id          = line_items.report_id
          AND  er.employee_id = get_my_employee_id()
          AND  (
            er.status IN ('draft', 'rejected')
            OR is_workflow_awaiting_clarification(er.id, 'expense_reports')
          )
      )
    )
    -- Approver: active workflow assignee with standard edit permission
    OR (
      has_permission('expense.edit')
      AND is_workflow_assignee(line_items.report_id, 'expense_reports')
    )
  );

COMMENT ON POLICY line_items_update ON line_items IS
  'Allows UPDATE to: admins (all rows), employees with expense.edit on own '
  'draft/rejected/clarification reports, and active workflow assignees with '
  'expense.edit (dynamic gate — no separate expense.edit_approval needed). '
  'Approver path uses is_workflow_assignee() SECURITY DEFINER to avoid '
  'circular RLS recursion on workflow_instances (migration 064). '
  'Migration 190: replaced expense.edit_approval with expense.edit.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm the rebuilt policy exists
SELECT policyname, cmd, qual, with_check
FROM   pg_policies
WHERE  tablename = 'line_items'
  AND  policyname = 'line_items_update';

-- 2. Confirm no other line_items UPDATE policy still references edit_approval
--    (should return 0 rows):
SELECT policyname, qual
FROM   pg_policies
WHERE  tablename = 'line_items'
  AND  cmd       = 'UPDATE'
  AND  (qual LIKE '%edit_approval%' OR with_check LIKE '%edit_approval%');

-- =============================================================================
-- END OF MIGRATION 190
--
-- No type regen needed — no schema changes, no new RPCs.
-- Frontend change (WorkflowReview.tsx) also updated to use can('expense.edit')
-- instead of can('expense.edit_approval') — deploy both together.
-- =============================================================================
