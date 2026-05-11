-- =============================================================================
-- Migration 153: Fix SELECT RLS on workflow template & notification tables
--
-- CONTEXT
-- ───────
-- Migrations 128 (wf_templates_user_can_rls) and 152 (wf_notification_config_module)
-- re-pointed INSERT / UPDATE / DELETE on four tables to user_can() correctly,
-- but left the SELECT policies as the original auth.uid() IS NOT NULL catch-all
-- (seeded in migration 030). Any authenticated user could read template
-- definitions and notification template bodies — even without any Workflow
-- Admin permission.
--
-- WHAT THIS DOES
-- ──────────────
-- 1. workflow_templates   SELECT → user_can('wf_templates',           'view', NULL)
-- 2. workflow_steps       SELECT → user_can('wf_templates',           'view', NULL)
-- 3. workflow_step_conditions SELECT → user_can('wf_templates',       'view', NULL)
-- 4. workflow_notification_templates SELECT → user_can('wf_notification_config', 'view', NULL)
--
-- POLICY TABLE AFTER THIS MIGRATION
-- ───────────────────────────────────
--   workflow_templates:
--     wf_templates_select  — user_can('wf_templates', 'view', NULL)
--     wf_templates_insert  — user_can('wf_templates', 'edit', NULL)   [unchanged]
--     wf_templates_update  — user_can('wf_templates', 'edit', NULL)   [unchanged]
--     wf_templates_delete  — user_can('wf_templates', 'edit', NULL)   [unchanged]
--
--   workflow_steps:
--     wf_steps_select  — user_can('wf_templates', 'view', NULL)
--     wf_steps_insert  — user_can('wf_templates', 'edit', NULL)       [unchanged]
--     wf_steps_update  — user_can('wf_templates', 'edit', NULL)       [unchanged]
--     wf_steps_delete  — user_can('wf_templates', 'edit', NULL)       [unchanged]
--
--   workflow_step_conditions:
--     wf_conditions_select  — user_can('wf_templates', 'view', NULL)
--     wf_conditions_insert  — user_can('wf_templates', 'edit', NULL)  [unchanged]
--     wf_conditions_update  — user_can('wf_templates', 'edit', NULL)  [unchanged]
--     wf_conditions_delete  — user_can('wf_templates', 'edit', NULL)  [unchanged]
--
--   workflow_notification_templates:
--     wf_notif_tmpl_select  — user_can('wf_notification_config', 'view', NULL)
--     wf_notif_tmpl_insert  — user_can('wf_notification_config', 'edit', NULL)  [unchanged]
--     wf_notif_tmpl_update  — user_can('wf_notification_config', 'edit', NULL)  [unchanged]
--     wf_notif_tmpl_delete  — user_can('wf_notification_config', 'edit', NULL)  [unchanged]
--
-- NOTE: workflow engine functions (trigger_workflow, advance_workflow_step, etc.)
-- are SECURITY DEFINER — they bypass RLS entirely and are unaffected by this change.
-- =============================================================================


-- ── 1. workflow_templates ─────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_templates_select ON workflow_templates;

CREATE POLICY wf_templates_select ON workflow_templates
  FOR SELECT
  USING (user_can('wf_templates', 'view', NULL));


-- ── 2. workflow_steps ─────────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_steps_select ON workflow_steps;

CREATE POLICY wf_steps_select ON workflow_steps
  FOR SELECT
  USING (user_can('wf_templates', 'view', NULL));


-- ── 3. workflow_step_conditions ───────────────────────────────────────────────

DROP POLICY IF EXISTS wf_conditions_select ON workflow_step_conditions;

CREATE POLICY wf_conditions_select ON workflow_step_conditions
  FOR SELECT
  USING (user_can('wf_templates', 'view', NULL));


-- ── 4. workflow_notification_templates ────────────────────────────────────────

DROP POLICY IF EXISTS wf_notif_tmpl_select ON workflow_notification_templates;

CREATE POLICY wf_notif_tmpl_select ON workflow_notification_templates
  FOR SELECT
  USING (user_can('wf_notification_config', 'view', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename IN (
  'workflow_templates',
  'workflow_steps',
  'workflow_step_conditions',
  'workflow_notification_templates'
)
ORDER  BY tablename, cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 153
-- =============================================================================
