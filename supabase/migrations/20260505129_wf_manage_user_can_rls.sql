-- =============================================================================
-- Migration 129: Upgrade workflow_instances & workflow_pending_changes RLS
--
-- TABLES COVERED
-- ──────────────
--   workflow_instances       — active workflow runs
--   workflow_pending_changes — pending field edits awaiting approval
--
-- POLICY SITUATION BEFORE THIS MIGRATION
-- ───────────────────────────────────────
-- workflow_instances has TWO overlapping SELECT policies (Postgres ORs them):
--   • wf_instances_select       (migration 030) — has_role + has_permission
--   • workflow_instances_select (migration 068) — has_permission expense.*
-- Both reference the dead role_permissions / has_permission system.
-- Admin writes covered by wf_instances_admin FOR ALL (has_role + has_permission).
--
-- workflow_pending_changes:
--   • wpc_select  — submitted_by | has_role | has_permission(workflow.*)
--   • wpc_insert  — auth.uid() IS NOT NULL (kept — written via SECURITY DEFINER)
--   • wpc_update  — has_role | has_permission(workflow.admin)
--
-- WHAT THIS MIGRATION DOES
-- ────────────────────────
-- 1. Drops both overlapping SELECT policies on workflow_instances and
--    replaces with a single clean policy using user_can('wf_manage','view',NULL).
-- 2. Drops the FOR ALL admin catch-all; adds explicit insert/update/delete
--    policies using user_can('wf_manage', 'edit', NULL).
-- 3. Replaces wpc_select and wpc_update with user_can() equivalents.
--    wpc_insert is left unchanged (open to authenticated — SECURITY DEFINER
--    functions are the only real callers and bypass RLS anyway).
-- =============================================================================


-- ── 1. Seed wf_manage.edit permission ────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_manage.edit'                                                  AS code,
  'Manage Workflows'                                                AS name,
  'Grants update / delete access to workflow instances and changes' AS description,
  m.id                                                              AS module_id,
  'edit'                                                            AS action
FROM modules m
WHERE m.code = 'wf_manage'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. workflow_instances ─────────────────────────────────────────────────────

-- Drop both overlapping SELECT policies and the FOR ALL admin catch-all.
DROP POLICY IF EXISTS wf_instances_select        ON workflow_instances;
DROP POLICY IF EXISTS workflow_instances_select  ON workflow_instances;
DROP POLICY IF EXISTS wf_instances_admin         ON workflow_instances;

-- Single consolidated SELECT:
--   • submitter always sees their own instance
--   • assigned approver sees instances they have a task on
--   • wf_manage.view holders see all (Workflow Admin in the matrix)
CREATE POLICY wf_instances_select ON workflow_instances FOR SELECT
  USING (
    submitted_by = auth.uid()
    OR user_can('wf_manage', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.instance_id = workflow_instances.id
        AND wt.assigned_to = auth.uid()
    )
  );

-- Explicit write policies — only wf_manage.edit holders can mutate instances.
CREATE POLICY wf_instances_insert ON workflow_instances
  FOR INSERT
  WITH CHECK (user_can('wf_manage', 'edit', NULL));

CREATE POLICY wf_instances_update ON workflow_instances
  FOR UPDATE
  USING      (user_can('wf_manage', 'edit', NULL))
  WITH CHECK (user_can('wf_manage', 'edit', NULL));

CREATE POLICY wf_instances_delete ON workflow_instances
  FOR DELETE
  USING (user_can('wf_manage', 'edit', NULL));


-- ── 3. workflow_pending_changes ───────────────────────────────────────────────

DROP POLICY IF EXISTS wpc_select ON workflow_pending_changes;
DROP POLICY IF EXISTS wpc_update ON workflow_pending_changes;

-- SELECT: submitter sees own; wf_manage.view holders see all.
CREATE POLICY wpc_select ON workflow_pending_changes FOR SELECT
  USING (
    submitted_by = auth.uid()
    OR user_can('wf_manage', 'view', NULL)
  );

-- INSERT unchanged — comment preserved from migration 046:
-- "Inserts and updates only via SECURITY DEFINER functions; auth.uid() IS NOT NULL
--  is the minimum gate; the SECURITY DEFINER function enforces business rules."

-- UPDATE: only wf_manage.edit holders (workflow admin actions).
CREATE POLICY wpc_update ON workflow_pending_changes
  FOR UPDATE
  USING      (user_can('wf_manage', 'edit', NULL))
  WITH CHECK (user_can('wf_manage', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('workflow_instances', 'workflow_pending_changes')
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('wf_manage.view', 'wf_manage.edit')
ORDER  BY code;
