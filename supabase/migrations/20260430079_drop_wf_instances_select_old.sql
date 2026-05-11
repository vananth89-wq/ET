-- =============================================================================
-- Migration 079: Drop stale wf_instances_select policy (cross-recursion fix)
--
-- ROOT CAUSE
-- ══════════
-- Two SELECT policies coexist on workflow_instances:
--
--   1. wf_instances_select (migration 030 — never dropped)
--        OR EXISTS (SELECT 1 FROM workflow_tasks wt WHERE wt.instance_id = ...)
--      ↑ queries workflow_tasks inline WITH RLS
--
--   2. workflow_instances_select (migration 068 — clean)
--        submitted_by = auth.uid()
--        OR has_permission('expense.view_org') ...
--      ↑ no reference to workflow_tasks — no recursion
--
-- Because multiple SELECT policies are OR'd, BOTH fire when workflow_instances
-- is queried. The old policy (1) triggers wf_tasks_select, which queries
-- workflow_instances again → which triggers both policies again → ∞.
--
--   wf_tasks_select → workflow_instances → wf_instances_select
--     → workflow_tasks → wf_tasks_select → ... (infinite recursion)
--
-- FIX
-- ═══
-- Drop the old wf_instances_select. Migration 068's workflow_instances_select
-- already covers submitters (submitted_by = auth.uid()) and managers
-- (has_permission views). Approver access is handled entirely via
-- SECURITY DEFINER RPCs (get_my_workflow_instance, get_my_workflow_tasks,
-- get_my_workflow_action_log) introduced in migration 069 — no direct table
-- select required.
-- =============================================================================

DROP POLICY IF EXISTS wf_instances_select ON workflow_instances;
DROP POLICY IF EXISTS wf_instances_admin  ON workflow_instances;

-- wf_instances_admin (migration 030) is superseded by the admin-ALL policies
-- created in later migrations. Drop it to clean up.
-- The workflow_instances_select policy from migration 068 remains as-is.

-- VERIFICATION: exactly one SELECT policy should remain on workflow_instances
SELECT policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_instances'
ORDER  BY cmd, policyname;
