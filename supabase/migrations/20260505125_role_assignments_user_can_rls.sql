-- =============================================================================
-- Migration 125: Upgrade roles & user_roles RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- roles and user_roles are still gated on has_role('admin') directly.
-- This means granting "Role Assignments" admin access in the Permission
-- Matrix UI has zero enforcement effect on these tables.
--
-- Migration 091 seeded the sec_role_assignments module with a .view
-- permission only. This migration adds sec_role_assignments.edit and
-- replaces all has_role('admin') write policies.
--
-- BOOTSTRAP SAFETY
-- ────────────────
-- user_roles is read by has_role() which is SECURITY DEFINER — it reads
-- the table as superuser and bypasses RLS entirely. user_can() also calls
-- has_role() internally via the same SECURITY DEFINER path.
-- No circular dependency: gating user_roles on user_can() is safe.
--
-- POLICIES CHANGED
-- ────────────────
--   roles      → roles_insert, roles_update, roles_delete
--   user_roles → user_roles_select (self-access preserved), user_roles_insert,
--                user_roles_update, user_roles_delete
--
-- POLICIES UNCHANGED
-- ──────────────────
--   roles → roles_select (USING auth.uid() IS NOT NULL AND active = true)
-- =============================================================================


-- ── 1. Seed sec_role_assignments.edit permission ──────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'sec_role_assignments.edit'                                      AS code,
  'Manage Role Assignments'                                        AS name,
  'Grants create / update / delete access to roles and user_roles' AS description,
  m.id                                                             AS module_id,
  'edit'                                                           AS action
FROM modules m
WHERE m.code = 'sec_role_assignments'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. roles: replace 3 write/delete policies ────────────────────────────────

DROP POLICY IF EXISTS roles_insert ON roles;
DROP POLICY IF EXISTS roles_update ON roles;
DROP POLICY IF EXISTS roles_delete ON roles;

CREATE POLICY roles_insert ON roles
  FOR INSERT
  WITH CHECK (user_can('sec_role_assignments', 'edit', NULL));

CREATE POLICY roles_update ON roles
  FOR UPDATE
  USING      (user_can('sec_role_assignments', 'edit', NULL))
  WITH CHECK (user_can('sec_role_assignments', 'edit', NULL));

-- Preserve the is_system = false guard that prevents deletion of built-in roles.
CREATE POLICY roles_delete ON roles
  FOR DELETE
  USING (user_can('sec_role_assignments', 'edit', NULL) AND is_system = false);


-- ── 3. user_roles: replace all 4 policies ────────────────────────────────────
-- SELECT: keep self-access (profile_id = auth.uid()) so AuthContext still works;
--         admin access now requires sec_role_assignments.edit.

DROP POLICY IF EXISTS user_roles_select ON user_roles;
DROP POLICY IF EXISTS user_roles_insert ON user_roles;
DROP POLICY IF EXISTS user_roles_update ON user_roles;
DROP POLICY IF EXISTS user_roles_delete ON user_roles;

CREATE POLICY user_roles_select ON user_roles
  FOR SELECT
  USING (profile_id = auth.uid() OR user_can('sec_role_assignments', 'edit', NULL));

CREATE POLICY user_roles_insert ON user_roles
  FOR INSERT
  WITH CHECK (user_can('sec_role_assignments', 'edit', NULL));

CREATE POLICY user_roles_update ON user_roles
  FOR UPDATE
  USING      (user_can('sec_role_assignments', 'edit', NULL))
  WITH CHECK (user_can('sec_role_assignments', 'edit', NULL));

CREATE POLICY user_roles_delete ON user_roles
  FOR DELETE
  USING (user_can('sec_role_assignments', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE tablename IN ('roles', 'user_roles')
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('sec_role_assignments.view', 'sec_role_assignments.edit')
ORDER  BY code;
