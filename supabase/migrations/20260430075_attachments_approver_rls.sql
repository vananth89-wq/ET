-- =============================================================================
-- Migration 075: Fix attachments_select RLS — allow workflow approvers
--
-- Problem: Managers assigned as approvers via workflow_tasks could not see
-- attachments on expense reports in the Workflow Inbox / WorkflowReview screen.
-- The attachments table's SELECT policy only checked org hierarchy and direct
-- reporting relationships — it had no clause for "is an active workflow approver
-- for this report".
--
-- Fix: Add a module-agnostic approver clause. Instead of joining through
-- expense_reports specifically, we join workflow_instances.record_id directly
-- to line_items.report_id — the parent record ID regardless of which module
-- table owns the record. This means the clause works for any future module
-- that also uses line_items + attachments.
-- =============================================================================

DROP POLICY IF EXISTS attachments_select ON attachments;

CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id
        AND er.deleted_at IS NULL
        AND (
          -- Admin sees everything
          has_role('admin')

          -- Org-wide viewers
          OR (has_permission('expense.view_org')
                AND er.status != 'draft')

          -- Team viewers (org subtree)
          OR (has_permission('expense.view_team')
                AND er.status != 'draft'
                AND is_in_my_org_subtree(er.employee_id))

          -- Direct-report viewers
          OR (has_permission('expense.view_direct')
                AND er.status != 'draft'
                AND is_my_direct_report(er.employee_id))

          -- Employee sees their own
          OR (has_permission('expense.view_own')
                AND er.employee_id = get_my_employee_id())

          -- ✅ Workflow approver — module-agnostic:
          --    wi.record_id = li.report_id works for any module whose
          --    workflow_instance.record_id points to the parent record
          --    that line_items.report_id also points to.
          --    No hardcoded reference to expense_reports here.
          OR EXISTS (
            SELECT 1
            FROM   workflow_tasks     wt
            JOIN   workflow_instances wi ON wi.id = wt.instance_id
            WHERE  wi.record_id   = li.report_id
              AND  wt.assigned_to = auth.uid()
              AND  wt.status      = 'pending'
          )
        )
    )
  );

COMMENT ON POLICY attachments_select ON attachments IS
  'Allows reading attachments when the viewer owns the report, is in the '
  'org hierarchy, has a broad view permission, or is an active workflow '
  'approver (pending task whose workflow_instance.record_id = line_items.report_id). '
  'The approver clause is module-agnostic — no hardcoded reference to expense_reports.';
