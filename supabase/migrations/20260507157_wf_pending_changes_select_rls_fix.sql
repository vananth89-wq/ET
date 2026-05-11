-- =============================================================================
-- Migration 157: Fix SELECT RLS on workflow_pending_changes
--
-- CONTEXT
-- ───────
-- Migration 129 set wpc_select to:
--   submitted_by = auth.uid() OR user_can('wf_manage','view',NULL)
--
-- This misses the assigned approver. A pending change is submitted through
-- the workflow engine — it gets a workflow_instance, and that instance has
-- workflow_tasks assigned to approvers. Those approvers need to SELECT the
-- pending change row to read what they are being asked to approve.
-- Without this clause the approval flow breaks — the approver can see the
-- task (via wf_tasks_select) but cannot read the change payload.
--
-- WHAT THIS DOES
-- ──────────────
-- Replaces:
--   wpc_select USING (
--     submitted_by = auth.uid()
--     OR user_can('wf_manage','view',NULL)
--   )
--
-- With:
--   wpc_select USING (
--     submitted_by = auth.uid()
--     OR user_can('wf_manage','view',NULL)
--     OR EXISTS (
--       SELECT 1 FROM workflow_tasks wt
--       WHERE wt.instance_id = workflow_pending_changes.instance_id
--         AND wt.assigned_to = auth.uid()
--     )
--   )
--
-- NOTE: workflow_pending_changes has no assigned_to column — the approver
-- link is through instance_id → workflow_tasks. The EXISTS subquery mirrors
-- the same pattern used on workflow_instances SELECT (migration 129).
--
-- INSERT policy (auth.uid() IS NOT NULL) is correct and unchanged — any
-- authenticated user may submit via wf_submit() SECURITY DEFINER RPC.
-- UPDATE/DELETE policies unchanged.
-- =============================================================================


DROP POLICY IF EXISTS wpc_select ON workflow_pending_changes;

-- Submitter sees their own request.
-- Assigned approver sees changes they need to action (via workflow_tasks).
-- Workflow managers (wf_manage.view) see all pending changes.
CREATE POLICY wpc_select ON workflow_pending_changes FOR SELECT
  USING (
    submitted_by = auth.uid()
    OR user_can('wf_manage', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.instance_id = workflow_pending_changes.instance_id
        AND wt.assigned_to = auth.uid()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_pending_changes'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 157
-- =============================================================================
