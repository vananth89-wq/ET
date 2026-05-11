-- =============================================================================
-- Migration 128: Upgrade workflow template tables RLS to user_can()
--
-- TABLES COVERED
-- ──────────────
--   workflow_templates       — template definitions
--   workflow_steps           — steps within a template
--   workflow_step_conditions — conditions on step transitions
--
-- BACKGROUND
-- ──────────
-- All three tables use a single FOR ALL policy gated on has_role('admin').
-- FOR ALL covers INSERT / UPDATE / DELETE and SELECT, but each table also
-- has a separate _select policy (USING auth.uid() IS NOT NULL) that keeps
-- reads open to all authenticated users. Postgres ORs all policies per
-- operation, so the SELECT is already open regardless of the FOR ALL.
--
-- We drop the _admin_all catch-all and replace it with explicit write
-- policies gated on user_can('wf_templates', 'edit', NULL).
-- The open _select policies are left unchanged.
--
-- POLICIES CHANGED
-- ────────────────
--   wf_templates_admin_all   → wf_templates_insert / _update / _delete
--   wf_steps_admin_all       → wf_steps_insert / _update / _delete
--   wf_conditions_admin_all  → wf_conditions_insert / _update / _delete
--
-- POLICIES UNCHANGED
-- ──────────────────
--   wf_templates_select, wf_steps_select, wf_conditions_select
--   (all remain USING auth.uid() IS NOT NULL)
-- =============================================================================


-- ── 1. Seed wf_templates.edit permission ─────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_templates.edit'                                                AS code,
  'Manage Workflow Templates'                                        AS name,
  'Grants create / update / delete access to workflow templates'    AS description,
  m.id                                                               AS module_id,
  'edit'                                                             AS action
FROM modules m
WHERE m.code = 'wf_templates'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. workflow_templates ─────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_templates_admin_all ON workflow_templates;

CREATE POLICY wf_templates_insert ON workflow_templates
  FOR INSERT
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_templates_update ON workflow_templates
  FOR UPDATE
  USING      (user_can('wf_templates', 'edit', NULL))
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_templates_delete ON workflow_templates
  FOR DELETE
  USING (user_can('wf_templates', 'edit', NULL));


-- ── 3. workflow_steps ─────────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_steps_admin_all ON workflow_steps;

CREATE POLICY wf_steps_insert ON workflow_steps
  FOR INSERT
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_steps_update ON workflow_steps
  FOR UPDATE
  USING      (user_can('wf_templates', 'edit', NULL))
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_steps_delete ON workflow_steps
  FOR DELETE
  USING (user_can('wf_templates', 'edit', NULL));


-- ── 4. workflow_step_conditions ───────────────────────────────────────────────

DROP POLICY IF EXISTS wf_conditions_admin_all ON workflow_step_conditions;

CREATE POLICY wf_conditions_insert ON workflow_step_conditions
  FOR INSERT
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_conditions_update ON workflow_step_conditions
  FOR UPDATE
  USING      (user_can('wf_templates', 'edit', NULL))
  WITH CHECK (user_can('wf_templates', 'edit', NULL));

CREATE POLICY wf_conditions_delete ON workflow_step_conditions
  FOR DELETE
  USING (user_can('wf_templates', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN (
  'workflow_templates', 'workflow_steps', 'workflow_step_conditions'
)
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('wf_templates.view', 'wf_templates.edit')
ORDER  BY code;
