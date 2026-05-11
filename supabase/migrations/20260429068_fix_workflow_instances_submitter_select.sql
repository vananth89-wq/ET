-- =============================================================================
-- Migration 068: Allow submitters to read their own workflow instances & tasks
--
-- Gap: workflow_instances_select only permitted expense.view_org / view_team /
-- view_direct holders.  Regular ESS employees (expense.submit) could not read
-- the workflow_instance for their own submission, so:
--   • useWorkflowInstance() returned null for the submitter
--   • ApprovalFlow showed all template steps as gray/pending
--   • WorkflowTimeline in ReportDetail showed nothing
--
-- Fix:
--   Add `submitted_by = auth.uid()` as an OR clause.  Employees can now read
--   instances they created — no other rows are exposed.
--
-- workflow_tasks is already correct:
--   wf_tasks_select has `EXISTS (wi.submitted_by = auth.uid())` but that
--   subquery was blocked by RLS on workflow_instances.  Fixing instances
--   automatically unblocks tasks for submitters too.
-- =============================================================================

DROP POLICY IF EXISTS workflow_instances_select ON workflow_instances;

CREATE POLICY workflow_instances_select ON workflow_instances FOR SELECT
  USING (
    submitted_by = auth.uid()               -- submitter can always see their own
    OR has_permission('expense.view_org')
    OR has_permission('expense.view_team')
    OR has_permission('expense.view_direct')
  );

COMMENT ON POLICY workflow_instances_select ON workflow_instances IS
  'Submitters can read their own instances; managers/admins see their scope.
   Fixed in migration 068: submitted_by = auth.uid() clause added.';


-- VERIFICATION
SELECT policyname, qual
FROM   pg_policies
WHERE  tablename  = 'workflow_instances'
  AND  policyname = 'workflow_instances_select';
