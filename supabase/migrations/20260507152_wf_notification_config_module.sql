-- =============================================================================
-- Migration 152: Introduce wf_notification_config module
--
-- CONTEXT
-- ───────
-- workflow_notification_templates write RLS was gated on wf_notifications.edit
-- (the Notification Monitor module). Managing templates is a distinct admin
-- concern from monitoring the notification queue, so it deserves its own
-- permission.
--
-- WHAT THIS DOES
-- ──────────────
-- 1. Seeds module wf_notification_config (sort_order 402 — between Templates
--    and wf_delegations in the sidebar)
-- 2. Seeds wf_notification_config.view + wf_notification_config.edit
-- 3. Re-points workflow_notification_templates write RLS from
--    wf_notifications.edit → wf_notification_config.edit
--
-- POLICIES AFTER THIS MIGRATION
-- ──────────────────────────────
--   workflow_notification_templates:
--     wf_notif_tmpl_select  — unchanged (auth.uid() IS NOT NULL)
--     wf_notif_tmpl_insert  — wf_notification_config.edit
--     wf_notif_tmpl_update  — wf_notification_config.edit
--     wf_notif_tmpl_delete  — wf_notification_config.edit
-- =============================================================================


-- ── 1. Seed module ────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES ('wf_notification_config', 'Manage Notifications', true, 402)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ── 2. Seed view + edit permissions ──────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_notification_config.view'                                           AS code,
  'View Notification Templates'                                           AS name,
  'Grants read access to the Manage Notifications tab and template list' AS description,
  m.id                                                                    AS module_id,
  'view'                                                                  AS action
FROM modules m WHERE m.code = 'wf_notification_config'
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description;

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_notification_config.edit'                                                      AS code,
  'Manage Notification Templates'                                                    AS name,
  'Grants create / update / delete access to workflow notification templates'        AS description,
  m.id                                                                               AS module_id,
  'edit'                                                                             AS action
FROM modules m WHERE m.code = 'wf_notification_config'
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description;


-- ── 3. Re-point workflow_notification_templates write RLS ─────────────────────

DROP POLICY IF EXISTS wf_notif_tmpl_insert ON workflow_notification_templates;
DROP POLICY IF EXISTS wf_notif_tmpl_update ON workflow_notification_templates;
DROP POLICY IF EXISTS wf_notif_tmpl_delete ON workflow_notification_templates;

CREATE POLICY wf_notif_tmpl_insert ON workflow_notification_templates
  FOR INSERT
  WITH CHECK (user_can('wf_notification_config', 'edit', NULL));

CREATE POLICY wf_notif_tmpl_update ON workflow_notification_templates
  FOR UPDATE
  USING      (user_can('wf_notification_config', 'edit', NULL))
  WITH CHECK (user_can('wf_notification_config', 'edit', NULL));

CREATE POLICY wf_notif_tmpl_delete ON workflow_notification_templates
  FOR DELETE
  USING (user_can('wf_notification_config', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT code, name, action FROM permissions
WHERE  code IN ('wf_notification_config.view', 'wf_notification_config.edit')
ORDER  BY code;

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'workflow_notification_templates'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 152
-- =============================================================================
