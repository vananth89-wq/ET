-- =============================================================================
-- Migration 126: Upgrade permission catalog tables RLS to user_can()
--
-- TABLES COVERED
-- ──────────────
--   modules, permissions            (core catalog — open read, admin write)
--   permission_sets                 (set definitions)
--   permission_set_items            (set contents — insert/delete only, no update)
--   permission_set_assignments      (who holds which set)
--
-- BOOTSTRAP SAFETY — WHY is_super_admin() IS REQUIRED HERE
-- ─────────────────────────────────────────────────────────
-- user_can() reads permission_set_assignments → permission_set_items to resolve
-- every permission check. If we gate these tables on user_can() alone, a super
-- admin who accidentally removes their own sec_permission_catalog.edit grant
-- creates a lockout: user_can() is SECURITY DEFINER so it reads through RLS
-- fine, but the admin UI SELECT (which IS subject to RLS) would be denied,
-- preventing them from fixing the catalog.
--
-- Safeguard: ALL write policies on these five tables use
--   is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL)
-- Super admins are in the super_admins UUID allowlist (migration 112) and
-- are never permission-driven — they can always recover a broken catalog.
--
-- READ POLICIES (unchanged)
-- ─────────────────────────
--   modules, permissions                → auth.uid() IS NOT NULL (open to all authenticated)
--   permission_sets, _items, _assignments → USING (true) (needed for Matrix UI)
-- =============================================================================


-- ── 1. Seed sec_permission_catalog.edit permission ───────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'sec_permission_catalog.edit'                                          AS code,
  'Manage Permission Catalog'                                            AS name,
  'Grants create / update / delete access to the permission catalog'    AS description,
  m.id                                                                   AS module_id,
  'edit'                                                                 AS action
FROM modules m
WHERE m.code = 'sec_permission_catalog'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. modules ────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS modules_insert ON modules;
DROP POLICY IF EXISTS modules_update ON modules;
DROP POLICY IF EXISTS modules_delete ON modules;

CREATE POLICY modules_insert ON modules
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY modules_update ON modules
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL))
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY modules_delete ON modules
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));


-- ── 3. permissions ────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS permissions_insert ON permissions;
DROP POLICY IF EXISTS permissions_update ON permissions;
DROP POLICY IF EXISTS permissions_delete ON permissions;

CREATE POLICY permissions_insert ON permissions
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY permissions_update ON permissions
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL))
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY permissions_delete ON permissions
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));


-- ── 4. permission_sets ────────────────────────────────────────────────────────

DROP POLICY IF EXISTS pset_insert ON permission_sets;
DROP POLICY IF EXISTS pset_update ON permission_sets;
DROP POLICY IF EXISTS pset_delete ON permission_sets;

CREATE POLICY pset_insert ON permission_sets
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY pset_update ON permission_sets
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY pset_delete ON permission_sets
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));


-- ── 5. permission_set_items ───────────────────────────────────────────────────
-- No UPDATE policy by design — items are immutable; delete + re-insert to change.

DROP POLICY IF EXISTS psi_insert ON permission_set_items;
DROP POLICY IF EXISTS psi_delete ON permission_set_items;

CREATE POLICY psi_insert ON permission_set_items
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY psi_delete ON permission_set_items
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));


-- ── 6. permission_set_assignments ─────────────────────────────────────────────

DROP POLICY IF EXISTS psa_insert ON permission_set_assignments;
DROP POLICY IF EXISTS psa_update ON permission_set_assignments;
DROP POLICY IF EXISTS psa_delete ON permission_set_assignments;

CREATE POLICY psa_insert ON permission_set_assignments
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY psa_update ON permission_set_assignments
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));

CREATE POLICY psa_delete ON permission_set_assignments
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_catalog', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN (
  'modules', 'permissions',
  'permission_sets', 'permission_set_items', 'permission_set_assignments'
)
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('sec_permission_catalog.view', 'sec_permission_catalog.edit')
ORDER  BY code;
