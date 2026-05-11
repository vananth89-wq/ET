-- =============================================================================
-- Migration 154: Fix SELECT RLS on workflow_tasks — swap wf_assignments.view
--                for wf_manage.view
--
-- CONTEXT
-- ───────
-- Migration 131 (wf_assignments_user_can_rls) set the wf_tasks_select policy to
-- allow wf_assignments.view holders to see all tasks. However, wf_assignments
-- is the module for configuring template-to-module routing rules — it is an
-- admin setup concern and has nothing to do with monitoring running workflow
-- tasks.
--
-- The correct "see all tasks" audience is wf_manage.view — Workflow Managers
-- who monitor and operate running workflows and legitimately need full task
-- visibility.
--
-- WHAT THIS DOES
-- ──────────────
-- Replaces:
--   wf_tasks_select USING (
--     assigned_to = auth.uid()
--     OR user_can('wf_assignments', 'view', NULL)
--     OR EXISTS (submitter check)
--   )
--
-- With:
--   wf_tasks_select USING (
--     assigned_to = auth.uid()
--     OR user_can('wf_manage', 'view', NULL)
--     OR EXISTS (submitter check)
--   )
--
-- NOTE: INSERT / UPDATE / DELETE policies on workflow_tasks are gated on
-- wf_assignments.edit but are never reached in practice — all writes go
-- through SECURITY DEFINER RPCs (wf_submit, wf_approve, etc.) which bypass
-- RLS entirely. Those policies are left unchanged.
-- =============================================================================


DROP POLICY IF EXISTS wf_tasks_select ON workflow_tasks;

-- Assignee sees their own tasks.
-- Submitter of the parent instance sees all tasks for that instance.
-- Workflow Managers (wf_manage.view) see all tasks across all instances.
CREATE POLICY wf_tasks_select ON workflow_tasks FOR SELECT
  USING (
    assigned_to = auth.uid()
    OR user_can('wf_manage', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.id = workflow_tasks.instance_id
        AND wi.submitted_by = auth.uid()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_tasks'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 154
-- =============================================================================
