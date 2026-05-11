-- =============================================================================
-- Migration 156: Tighten workflow_delegations RLS — require wf_inbox.view
--                for self-service delegation operations
--
-- CONTEXT
-- ───────
-- Migration 132 (wf_delegations_user_can_rls) set the self-service clause as
-- delegator_id = auth.uid() — allowing ANY authenticated user to create or
-- manage their own delegations regardless of whether they are an approver.
--
-- In practice only approvers (wf_inbox.view holders) should be able to set up
-- delegations — you can only delegate approval rights you actually have.
-- A non-approver creating a delegation is meaningless and should be blocked.
--
-- PATH B — no target population
-- ──────────────────────────────
-- All user_can() calls use NULL as the target (module-level check).
-- No scope/target group filtering is required for delegation permissions.
--
-- POLICIES AFTER THIS MIGRATION
-- ──────────────────────────────
--   SELECT  — (delegator_id = auth.uid() AND wf_inbox.view)
--             OR delegate_id = auth.uid()
--             OR wf_delegations.view
--             Note: delegate_id check has no wf_inbox guard — the delegate
--             is a passive recipient and needs to see they are covering.
--
--   INSERT  — (delegator_id = auth.uid() AND wf_inbox.view)
--             OR wf_delegations.edit
--
--   UPDATE  — (delegator_id = auth.uid() AND wf_inbox.view)
--             OR wf_delegations.edit
--
--   DELETE  — (delegator_id = auth.uid() AND wf_inbox.view)
--             OR wf_delegations.edit
-- =============================================================================


DROP POLICY IF EXISTS wf_delegations_select ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_insert ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_update ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_delete ON workflow_delegations;


-- SELECT: approver sees own rows; delegate always sees rows where they cover;
--         admin (wf_delegations.view) sees all.
CREATE POLICY wf_delegations_select ON workflow_delegations FOR SELECT
  USING (
    (delegator_id = auth.uid() AND user_can('wf_inbox', 'view', NULL))
    OR delegate_id = auth.uid()
    OR user_can('wf_delegations', 'view', NULL)
  );

-- INSERT: approver creates own delegation; admin creates for anyone.
CREATE POLICY wf_delegations_insert ON workflow_delegations FOR INSERT
  WITH CHECK (
    (delegator_id = auth.uid() AND user_can('wf_inbox', 'view', NULL))
    OR user_can('wf_delegations', 'edit', NULL)
  );

-- UPDATE: approver edits own; admin edits any.
CREATE POLICY wf_delegations_update ON workflow_delegations FOR UPDATE
  USING (
    (delegator_id = auth.uid() AND user_can('wf_inbox', 'view', NULL))
    OR user_can('wf_delegations', 'edit', NULL)
  )
  WITH CHECK (
    (delegator_id = auth.uid() AND user_can('wf_inbox', 'view', NULL))
    OR user_can('wf_delegations', 'edit', NULL)
  );

-- DELETE: approver cancels own; admin deletes any.
CREATE POLICY wf_delegations_delete ON workflow_delegations FOR DELETE
  USING (
    (delegator_id = auth.uid() AND user_can('wf_inbox', 'view', NULL))
    OR user_can('wf_delegations', 'edit', NULL)
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_delegations'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 156
-- =============================================================================
