-- =============================================================================
-- Migration 133: Upgrade workflow notification tables RLS to user_can()
--
-- TABLES COVERED
-- ──────────────
--   workflow_notification_templates — email/push template definitions
--   workflow_notification_queue     — pending and delivered notification jobs
--
-- CURRENT STATE
-- ─────────────
--   workflow_notification_templates:
--     wf_notif_tmpl_select  — USING (auth.uid() IS NOT NULL)  [kept]
--     wf_notif_tmpl_admin   — FOR ALL, has_role('admin')
--
--   workflow_notification_queue:
--     wf_notif_queue_admin  — FOR ALL, has_role + has_permission('workflow.admin')
--
-- workflow_notification_queue rows are inserted by a SECURITY DEFINER trigger
-- (after_wf_notification_queue_insert). The FOR ALL policy still governs any
-- direct admin reads and status updates (e.g. retries, monitoring).
--
-- POLICIES AFTER THIS MIGRATION
-- ──────────────────────────────
--   workflow_notification_templates:
--     wf_notif_tmpl_select  — unchanged (auth.uid() IS NOT NULL)
--     wf_notif_tmpl_insert / _update / _delete → user_can('wf_notifications','edit')
--
--   workflow_notification_queue:
--     wf_notif_queue_select → user_can('wf_notifications','view')
--     wf_notif_queue_insert / _update → user_can('wf_notifications','edit')
-- =============================================================================


-- ── 1. Seed wf_notifications.edit permission ──────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_notifications.edit'                                                     AS code,
  'Manage Workflow Notifications'                                              AS name,
  'Grants admin access to notification templates and queue management'        AS description,
  m.id                                                                         AS module_id,
  'edit'                                                                       AS action
FROM modules m
WHERE m.code = 'wf_notifications'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. workflow_notification_templates ────────────────────────────────────────
-- wf_notif_tmpl_select (auth.uid() IS NOT NULL) is unchanged — templates are
-- read during notification rendering by any authenticated context.

DROP POLICY IF EXISTS wf_notif_tmpl_admin ON workflow_notification_templates;

CREATE POLICY wf_notif_tmpl_insert ON workflow_notification_templates
  FOR INSERT
  WITH CHECK (user_can('wf_notifications', 'edit', NULL));

CREATE POLICY wf_notif_tmpl_update ON workflow_notification_templates
  FOR UPDATE
  USING      (user_can('wf_notifications', 'edit', NULL))
  WITH CHECK (user_can('wf_notifications', 'edit', NULL));

CREATE POLICY wf_notif_tmpl_delete ON workflow_notification_templates
  FOR DELETE
  USING (user_can('wf_notifications', 'edit', NULL));


-- ── 3. workflow_notification_queue ────────────────────────────────────────────

DROP POLICY IF EXISTS wf_notif_queue_admin ON workflow_notification_queue;

-- Admin monitoring — view the queue status and delivery outcomes.
CREATE POLICY wf_notif_queue_select ON workflow_notification_queue FOR SELECT
  USING (user_can('wf_notifications', 'view', NULL));

-- Writes cover manual retries and status patches by admins.
-- Routine inserts are made by a SECURITY DEFINER trigger and bypass RLS.
CREATE POLICY wf_notif_queue_insert ON workflow_notification_queue
  FOR INSERT
  WITH CHECK (user_can('wf_notifications', 'edit', NULL));

CREATE POLICY wf_notif_queue_update ON workflow_notification_queue
  FOR UPDATE
  USING      (user_can('wf_notifications', 'edit', NULL))
  WITH CHECK (user_can('wf_notifications', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN (
  'workflow_notification_templates', 'workflow_notification_queue'
)
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('wf_notifications.view', 'wf_notifications.edit')
ORDER  BY code;
