-- =============================================================================
-- Migration 174: Fix infinite recursion between workflow_tasks and
--               workflow_instances SELECT RLS policies
--
-- ROOT CAUSE
-- ──────────
-- Two SELECT policies create a circular dependency:
--
--   wf_tasks_select (workflow_tasks, mig 154):
--     USING (
--       assigned_to = auth.uid()
--       OR user_can('wf_manage', 'view', NULL)
--       OR EXISTS (
--         SELECT 1 FROM workflow_instances wi        ← queries workflow_instances
--         WHERE wi.id = workflow_tasks.instance_id
--           AND wi.submitted_by = auth.uid()
--       )
--     )
--
--   wf_instances_select (workflow_instances, mig 129):
--     USING (
--       submitted_by = auth.uid()
--       OR user_can('wf_manage', 'view', NULL)
--       OR EXISTS (
--         SELECT 1 FROM workflow_tasks wt            ← queries workflow_tasks
--         WHERE wt.instance_id = workflow_instances.id
--           AND wt.assigned_to = auth.uid()
--       )
--     )
--
-- When either table is queried, PostgreSQL evaluates both policies in turn,
-- each causing the other table to be queried, which re-triggers its RLS
-- policy → infinite recursion (PostgreSQL error 42P17).
--
-- This surfaces whenever workflow_tasks is read (loading the step list in
-- WorkflowTemplates fires a join that hits the RLS stack).
--
-- FIX (same pattern as migration 064)
-- ────────────────────────────────────
-- Create is_wf_task_assignee(instance_id) — a SECURITY DEFINER function that
-- reads workflow_tasks without triggering its RLS policies. Replace the inline
-- EXISTS subquery in wf_instances_select with this function to break the loop.
--
-- We fix the instances side (not the tasks side) because:
--   • wf_tasks_select is the "inner" table in the standard query path — the
--     inline EXISTS on instances is easier to audit from the task side.
--   • The SECURITY DEFINER function is scoped to a single instance_id,
--     making it cheap and readable.
--
-- CALLER IMPACT
-- ─────────────
-- No UI or application code changes needed. The fix is purely at the DB
-- policy layer. Both tables remain readable under the same logical rules:
--   workflow_tasks:    assignee | wf_manage.view | submitter of parent instance
--   workflow_instances: submitter | wf_manage.view | any assigned approver
-- =============================================================================


-- ── 1. SECURITY DEFINER helper ────────────────────────────────────────────────
--
-- Reads workflow_tasks as the function owner (bypasses caller RLS on that
-- table), so it can check task assignment without re-triggering wf_tasks_select.

CREATE OR REPLACE FUNCTION is_wf_task_assignee(p_instance_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_tasks wt
    WHERE  wt.instance_id = p_instance_id
      AND  wt.assigned_to = auth.uid()
  );
$$;

COMMENT ON FUNCTION is_wf_task_assignee(uuid) IS
  'Returns true if auth.uid() has any task assigned on the given workflow instance. '
  'SECURITY DEFINER — bypasses RLS on workflow_tasks to prevent the circular '
  'policy recursion between wf_tasks_select and wf_instances_select (mig 174).';


-- ── 2. Rebuild wf_instances_select using the helper ──────────────────────────

DROP POLICY IF EXISTS wf_instances_select ON workflow_instances;

-- Submitter sees their own instance.
-- Assigned approver sees instances they have a task on (via SECURITY DEFINER
-- helper to avoid circular RLS evaluation with workflow_tasks).
-- Workflow Managers (wf_manage.view) see all instances.
CREATE POLICY wf_instances_select ON workflow_instances FOR SELECT
  USING (
    submitted_by = auth.uid()
    OR user_can('wf_manage', 'view', NULL)
    OR is_wf_task_assignee(workflow_instances.id)
  );


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm helper created
SELECT proname, prosecdef
FROM   pg_proc
WHERE  proname = 'is_wf_task_assignee';

-- Confirm both SELECT policies exist and have no inline cross-reference
SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename IN ('workflow_tasks', 'workflow_instances')
  AND  cmd = 'SELECT'
ORDER  BY tablename, policyname;

-- =============================================================================
-- END OF MIGRATION 174
--
-- After applying: no type regen needed (no schema or function signature change).
-- Smoke-test: open WorkflowTemplates — step list should load without
-- "infinite recursion detected in policy for relation workflow_tasks" error.
-- =============================================================================
