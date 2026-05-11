-- =============================================================================
-- Migration 130: Upgrade workflow_action_log & workflow_sla_events RLS
--
-- TABLES COVERED
-- ──────────────
--   workflow_action_log  — immutable record of every workflow action taken
--   workflow_sla_events  — SLA breach events tied to workflow tasks
--
-- BACKGROUND
-- ──────────
-- Both tables are append-only logs written exclusively by SECURITY DEFINER
-- trigger functions — no INSERT/UPDATE/DELETE RLS policies exist or are
-- needed. Only the SELECT policies reference has_role() and need updating.
--
-- No new permission is seeded: wf_manage.view already exists (migration 091).
--
-- POLICIES CHANGED
-- ────────────────
--   wf_action_log_select  — replaces has_role + has_permission with user_can
--   wf_sla_select         — replaces has_role with user_can
--
-- VISIBILITY RULES PRESERVED
-- ──────────────────────────
--   workflow_action_log:
--     • actor can always see their own actions (actor_id = auth.uid())
--     • submitter of the parent instance can see the log
--     • assigned approver on any task of the instance can see the log
--     • wf_manage.view holders see all (Workflow Admin in matrix)
--   workflow_sla_events:
--     • assigned approver on the related task can see the event
--     • wf_manage.view holders see all
-- =============================================================================


-- ── 1. workflow_action_log ────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_action_log_select ON workflow_action_log;

CREATE POLICY wf_action_log_select ON workflow_action_log FOR SELECT
  USING (
    user_can('wf_manage', 'view', NULL)
    OR actor_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.id = workflow_action_log.instance_id
        AND (
          wi.submitted_by = auth.uid()
          OR EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = wi.id
              AND wt.assigned_to = auth.uid()
          )
        )
    )
  );


-- ── 2. workflow_sla_events ────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_sla_select ON workflow_sla_events;

CREATE POLICY wf_sla_select ON workflow_sla_events FOR SELECT
  USING (
    user_can('wf_manage', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.id = workflow_sla_events.task_id
        AND wt.assigned_to = auth.uid()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('workflow_action_log', 'workflow_sla_events')
ORDER BY tablename, cmd, policyname;
