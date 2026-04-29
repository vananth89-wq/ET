-- =============================================================================
-- Migration 057: RLS Delegation Self-Service + Policy Consistency
--
-- Fixes confirmed gaps from the permissions audit:
--
--   1. workflow_delegations — missing UPDATE and DELETE policies.
--      Users could SELECT and INSERT their own delegations but could not
--      edit or cancel them. Adds:
--        • wf_delegations_self_update  — delegator can edit their own rows
--        • wf_delegations_self_delete  — delegator can cancel their own rows
--      The existing wf_delegations_admin (FOR ALL) already covers admins,
--      so these new policies only need to cover the non-admin self-service case.
--
--   2. workflow_delegations — extend wf_delegations_own (INSERT) to also
--      accept has_permission('workflow.admin'), matching the pattern used
--      everywhere else in the workflow module.
--
--   3. workflow_delegations — extend wf_delegations_select (SELECT) to also
--      accept has_permission('workflow.admin').
--
-- Non-issues confirmed (no changes needed):
--   • workflow_notification_queue  — FOR ALL policy already covers SELECT
--   • notifications table          — SELECT policy exists (user_id = auth.uid())
--   • All non-workflow permission codes — already seeded in earlier migrations
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Drop and recreate SELECT / INSERT policies to add workflow.admin
-- ════════════════════════════════════════════════════════════════════════════

-- SELECT: admins, workflow.admin users, and parties to the delegation
DROP POLICY IF EXISTS wf_delegations_select ON workflow_delegations;

CREATE POLICY wf_delegations_select ON workflow_delegations FOR SELECT
  USING (
    has_role('admin')
    OR has_permission('workflow.admin')
    OR delegator_id = auth.uid()
    OR delegate_id  = auth.uid()
  );

COMMENT ON POLICY wf_delegations_select ON workflow_delegations IS
  'Allows admins, workflow.admin users, and the delegator/delegate to view '
  'delegation records.';


-- INSERT: delegators creating their own, or admin / workflow.admin
DROP POLICY IF EXISTS wf_delegations_own ON workflow_delegations;

CREATE POLICY wf_delegations_own ON workflow_delegations FOR INSERT
  WITH CHECK (
    delegator_id = auth.uid()
    OR has_role('admin')
    OR has_permission('workflow.admin')
  );

COMMENT ON POLICY wf_delegations_own ON workflow_delegations IS
  'Allows a user to create delegations on their own behalf, or admins / '
  'workflow.admin users to create delegations for anyone.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Add UPDATE policy — delegators can edit their own delegations
-- ════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS wf_delegations_self_update ON workflow_delegations;

CREATE POLICY wf_delegations_self_update ON workflow_delegations FOR UPDATE
  USING (
    delegator_id = auth.uid()
    OR has_role('admin')
    OR has_permission('workflow.admin')
  )
  WITH CHECK (
    delegator_id = auth.uid()
    OR has_role('admin')
    OR has_permission('workflow.admin')
  );

COMMENT ON POLICY wf_delegations_self_update ON workflow_delegations IS
  'Allows a delegator to modify their own delegation (e.g. change dates or '
  'deactivate it), or admins / workflow.admin users to modify any delegation.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Add DELETE policy — delegators can cancel their own delegations
-- ════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS wf_delegations_self_delete ON workflow_delegations;

CREATE POLICY wf_delegations_self_delete ON workflow_delegations FOR DELETE
  USING (
    delegator_id = auth.uid()
    OR has_role('admin')
    OR has_permission('workflow.admin')
  );

COMMENT ON POLICY wf_delegations_self_delete ON workflow_delegations IS
  'Allows a delegator to delete (cancel) their own delegation records, or '
  'admins / workflow.admin users to delete any delegation.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT
  policyname,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE tablename = 'workflow_delegations'
ORDER BY policyname;
