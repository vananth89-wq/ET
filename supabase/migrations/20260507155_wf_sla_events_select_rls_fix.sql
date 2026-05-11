-- =============================================================================
-- Migration 155: Fix SELECT RLS on wf_sla_events — use wf_performance.view
--
-- CONTEXT
-- ───────
-- Migration 130 set wf_sla_select to user_can('wf_manage','view',NULL) as a
-- placeholder. SLA breach events feed the Performance dashboard (cycle times,
-- SLA metrics, bottleneck analysis) — the correct permission is
-- wf_performance.view, which is the dedicated permission for that screen.
--
-- wf_manage.view is for operating/monitoring running workflows (trigger,
-- cancel, configure). wf_performance.view is specifically for reporting
-- and analytics consumers. These are distinct audiences.
--
-- WHAT THIS DOES
-- ──────────────
-- Replaces:
--   wf_sla_select USING (
--     user_can('wf_manage', 'view', NULL)
--     OR EXISTS (assignee check)
--   )
--
-- With:
--   wf_sla_select USING (
--     user_can('wf_performance', 'view', NULL)
--     OR EXISTS (assignee check)
--   )
-- =============================================================================


DROP POLICY IF EXISTS wf_sla_select ON workflow_sla_events;

-- Performance admins (wf_performance.view) see all SLA events for dashboards.
-- Assignee of the related task sees their own SLA events.
CREATE POLICY wf_sla_select ON workflow_sla_events FOR SELECT
  USING (
    user_can('wf_performance', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.id = workflow_sla_events.task_id
        AND wt.assigned_to = auth.uid()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_sla_events'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 155
-- =============================================================================
