-- =============================================================================
-- Migration 138: Upgrade projects RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- projects uses has_permission('project.*') which reads from the dead
-- role_permissions table. Granular codes (view/create/edit/delete) are
-- collapsed into two Permission Matrix toggles:
--   projects_mgmt.view — read access to the projects list
--   projects_mgmt.edit — full write access to projects
--
-- The `projects_mgmt` module already exists. Both permissions are new.
-- =============================================================================


-- ── 1. Seed projects_mgmt.view and projects_mgmt.edit permissions ─────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT p.code, p.name, p.description, m.id, p.action
FROM (VALUES
  ('projects_mgmt.view', 'View Projects',   'Grants read access to the projects list',          'view'),
  ('projects_mgmt.edit', 'Manage Projects', 'Grants create / update / delete access to projects', 'edit')
) AS p(code, name, description, action)
JOIN modules m ON m.code = 'projects_mgmt'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. projects ───────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS projects_select ON projects;
DROP POLICY IF EXISTS projects_insert ON projects;
DROP POLICY IF EXISTS projects_update ON projects;
DROP POLICY IF EXISTS projects_delete ON projects;

CREATE POLICY projects_select ON projects FOR SELECT
  USING (user_can('projects_mgmt', 'view', NULL));

CREATE POLICY projects_insert ON projects FOR INSERT
  WITH CHECK (user_can('projects_mgmt', 'edit', NULL));

CREATE POLICY projects_update ON projects FOR UPDATE
  USING      (user_can('projects_mgmt', 'edit', NULL))
  WITH CHECK (user_can('projects_mgmt', 'edit', NULL));

CREATE POLICY projects_delete ON projects FOR DELETE
  USING (user_can('projects_mgmt', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'projects'
ORDER BY cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('projects_mgmt.view', 'projects_mgmt.edit')
ORDER  BY code;
