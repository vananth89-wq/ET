-- =============================================================================
-- Migration 160: Harden workflow_pending_changes INSERT RLS
--
-- BUG
-- ───
-- Migration 046 created wpc_insert with an open gate:
--
--   WITH CHECK (auth.uid() IS NOT NULL)
--
-- This allows any authenticated user to INSERT directly into
-- workflow_pending_changes, bypassing wf_submit() and its business-rule
-- enforcement (valid template, duplicate-instance guard, approver routing).
--
-- In practice the risk is low — a rogue row stays in pending state
-- indefinitely because UPDATE is locked to wf_manage.edit and the row
-- cannot be approved without going through wf_approve() SECURITY DEFINER.
-- However the gate is inconsistent with all other workflow write policies.
--
-- FIX
-- ───
-- Replace auth.uid() IS NOT NULL with the same pattern used on workflow_tasks:
--
--   WITH CHECK (user_can('wf_manage', 'edit', NULL))
--
-- This keeps three paths working:
--   1. Regular employee → wf_submit() SECURITY DEFINER → bypasses RLS → ✓
--   2. Workflow admin direct insert → has wf_manage.edit → passes → ✓
--   3. Regular employee raw direct insert → no wf_manage.edit → blocked → ✗
--
-- No application code changes needed. wf_submit() is SECURITY DEFINER and
-- bypasses RLS entirely, so this policy change is invisible to it.
-- =============================================================================


DROP POLICY IF EXISTS wpc_insert ON workflow_pending_changes;

CREATE POLICY wpc_insert ON workflow_pending_changes
  FOR INSERT
  WITH CHECK (user_can('wf_manage', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT policyname, cmd, qual, with_check
FROM   pg_policies
WHERE  tablename = 'workflow_pending_changes'
ORDER  BY cmd, policyname;

-- Expected: wpc_insert FOR INSERT with_check = user_can('wf_manage','edit',NULL)

-- =============================================================================
-- END OF MIGRATION 160
-- =============================================================================
