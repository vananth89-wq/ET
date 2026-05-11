-- =============================================================================
-- Migration 064: Fix infinite recursion in approver RLS policies
--
-- Root cause:
--   The three approver policies added via SQL editor used inline EXISTS
--   subqueries that joined workflow_tasks → workflow_instances.
--   workflow_tasks itself has an RLS SELECT policy that references
--   expense_reports — creating a circular dependency:
--
--     expense_reports SELECT
--       → checks workflow_tasks (via approver policy)
--       → workflow_tasks SELECT policy checks expense_reports
--       → INFINITE RECURSION (Postgres error 42P17)
--
--   This crashed every expense_reports SELECT for ALL users (not just
--   approvers), causing useExpenseData to silently return reports = [].
--
-- Fix:
--   1. Create is_workflow_assignee() — a SECURITY DEFINER function that
--      reads workflow_tasks/instances without triggering their RLS policies,
--      breaking the cycle cleanly.
--   2. Drop the three broken approver policies.
--   3. Rebuild expense_reports_select, line_items_select, and
--      attachments_select to include the approver clause via the new
--      SECURITY DEFINER function.
-- =============================================================================


-- ── 1. SECURITY DEFINER helper ────────────────────────────────────────────────
--
-- Runs as the function owner (bypasses caller RLS on workflow_tasks and
-- workflow_instances), so it can safely look up task assignments without
-- triggering the recursion that inline EXISTS subqueries cause.

CREATE OR REPLACE FUNCTION is_workflow_assignee(
  p_record_id   uuid,
  p_module_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi ON wi.id = wt.instance_id
    WHERE  wi.record_id   = p_record_id
      AND  wi.module_code = p_module_code
      AND  wt.assigned_to = auth.uid()
  );
$$;

COMMENT ON FUNCTION is_workflow_assignee(uuid, text) IS
  'Returns true if the current user (auth.uid()) has a workflow task assigned '
  'on the given record. SECURITY DEFINER so it bypasses RLS on workflow_tasks '
  'and workflow_instances, preventing circular policy recursion.';


-- ── 2. Drop the broken approver policies ──────────────────────────────────────

DROP POLICY IF EXISTS expense_reports_approver_read ON expense_reports;
DROP POLICY IF EXISTS line_items_approver_read       ON line_items;
DROP POLICY IF EXISTS attachments_approver_read      ON attachments;


-- ── 3. Rebuild SELECT policies with approver clause ───────────────────────────

-- EXPENSE REPORTS
DROP POLICY IF EXISTS expense_reports_select ON expense_reports;

CREATE POLICY expense_reports_select ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_role('admin')
      OR (has_permission('expense.view_org')    AND status != 'draft')
      OR (has_permission('expense.view_team')   AND status != 'draft'
          AND is_in_my_org_subtree(employee_id))
      OR (has_permission('expense.view_direct') AND status != 'draft'
          AND is_my_direct_report(employee_id))
      OR (has_permission('expense.view_own')    AND employee_id = get_my_employee_id())
      OR is_workflow_assignee(id, 'expense_reports')
    )
  );

COMMENT ON POLICY expense_reports_select ON expense_reports IS
  'Grants SELECT to: admins (all), org-viewers (submitted+), team/direct '
  'viewers (submitted+ in scope), own-record holders (any status), and '
  'approvers via is_workflow_assignee() — SECURITY DEFINER to avoid recursion.';


-- LINE ITEMS
DROP POLICY IF EXISTS line_items_select ON line_items;

CREATE POLICY line_items_select ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM   expense_reports er
      WHERE  er.id         = line_items.report_id
        AND  er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')    AND er.status != 'draft')
          OR (has_permission('expense.view_team')   AND er.status != 'draft'
              AND is_in_my_org_subtree(er.employee_id))
          OR (has_permission('expense.view_direct') AND er.status != 'draft'
              AND is_my_direct_report(er.employee_id))
          OR (has_permission('expense.view_own')    AND er.employee_id = get_my_employee_id())
          OR is_workflow_assignee(er.id, 'expense_reports')
        )
    )
  );

COMMENT ON POLICY line_items_select ON line_items IS
  'Mirrors expense_reports_select. Uses is_workflow_assignee() for the '
  'approver clause to prevent recursive RLS evaluation.';


-- ATTACHMENTS
DROP POLICY IF EXISTS attachments_select ON attachments;

CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM   line_items     li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id          = attachments.line_item_id
        AND  er.deleted_at  IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')    AND er.status != 'draft')
          OR (has_permission('expense.view_team')   AND er.status != 'draft'
              AND is_in_my_org_subtree(er.employee_id))
          OR (has_permission('expense.view_direct') AND er.status != 'draft'
              AND is_my_direct_report(er.employee_id))
          OR (has_permission('expense.view_own')    AND er.employee_id = get_my_employee_id())
          OR is_workflow_assignee(er.id, 'expense_reports')
        )
    )
  );

COMMENT ON POLICY attachments_select ON attachments IS
  'Mirrors expense_reports_select. Uses is_workflow_assignee() for the '
  'approver clause to prevent recursive RLS evaluation.';


-- ── VERIFICATION ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM   pg_policies
WHERE  tablename IN ('expense_reports', 'line_items', 'attachments')
  AND  cmd = 'SELECT'
ORDER  BY tablename, policyname;
