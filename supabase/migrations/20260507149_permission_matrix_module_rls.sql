-- =============================================================================
-- Migration 149: Introduce sec_permission_matrix module + re-point write RLS
--
-- CONTEXT
-- ───────
-- The Permission Catalog tab (/admin/permissions/catalog) is READ-ONLY.
-- All actual writes to permission_sets, permission_set_items and
-- permission_set_assignments are performed exclusively by the Permission
-- Matrix tab (/admin/permissions/matrix).
--
-- Previously, write access to all three tables was gated on
-- user_can('sec_permission_catalog','edit',NULL).  That was wrong: the
-- catalog permission should only grant visibility into the read-only catalog
-- view; editing the matrix requires its own, dedicated permission.
--
-- CHANGES
-- ───────
-- 1. Add sec_permission_matrix module + view + edit permissions.
-- 2. Update write RLS on permission_sets, permission_set_items,
--    permission_set_assignments to require sec_permission_matrix.edit
--    (is_super_admin() bypass retained for lockout recovery).
-- 3. sec_permission_catalog.edit permission is no longer referenced by any
--    RLS policy.  It is left in the permissions table (removing it would
--    orphan any existing grants), but it grants no write access going forward.
--
-- ROUTING IMPLICATION (applied in App.tsx + Permission Matrix UI)
-- ───────────────────────────────────────────────────────────────
-- /admin/permissions/matrix is now gated by sec_permission_matrix.view.
-- /admin/permissions/assignments remains gated by sec_role_assignments.view.
-- The Permission Matrix toggle in the UI controls sec_permission_matrix.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Add the new module
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES ('sec_permission_matrix', 'Permission Matrix', true, 302)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;

-- Shift the sort order of later Security modules down by 1 to make room
UPDATE modules SET sort_order = sort_order + 1
WHERE  code IN (
  'sec_target_groups',
  'sec_permission_catalog',
  'sec_rbp_troubleshoot'
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Add view + edit permissions for the new module
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  m.code || '.view'                                         AS code,
  'View Permission Matrix'                                  AS name,
  'Grants access to the Permission Matrix tab — assign permission sets to roles with target groups' AS description,
  m.id                                                      AS module_id,
  'view'                                                    AS action
FROM modules m
WHERE m.code = 'sec_permission_matrix'
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description;

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  m.code || '.edit'                                         AS code,
  'Edit Permission Matrix'                                  AS name,
  'Grants create / update / delete access to permission_sets, permission_set_items and permission_set_assignments' AS description,
  m.id                                                      AS module_id,
  'edit'                                                    AS action
FROM modules m
WHERE m.code = 'sec_permission_matrix'
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Re-point write RLS on permission_sets
--    was: user_can('sec_permission_catalog','edit',NULL)
--    now: user_can('sec_permission_matrix','edit',NULL)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS pset_insert ON permission_sets;
DROP POLICY IF EXISTS pset_update ON permission_sets;
DROP POLICY IF EXISTS pset_delete ON permission_sets;

CREATE POLICY pset_insert ON permission_sets
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));

CREATE POLICY pset_update ON permission_sets
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL))
  WITH CHECK (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));

CREATE POLICY pset_delete ON permission_sets
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Re-point write RLS on permission_set_items
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS psi_insert ON permission_set_items;
DROP POLICY IF EXISTS psi_delete ON permission_set_items;

CREATE POLICY psi_insert ON permission_set_items
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));

CREATE POLICY psi_delete ON permission_set_items
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Re-point write RLS on permission_set_assignments
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS psa_insert ON permission_set_assignments;
DROP POLICY IF EXISTS psa_update ON permission_set_assignments;
DROP POLICY IF EXISTS psa_delete ON permission_set_assignments;

CREATE POLICY psa_insert ON permission_set_assignments
  FOR INSERT
  WITH CHECK (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));

CREATE POLICY psa_update ON permission_set_assignments
  FOR UPDATE
  USING      (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL))
  WITH CHECK (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));

CREATE POLICY psa_delete ON permission_set_assignments
  FOR DELETE
  USING (is_super_admin() OR user_can('sec_permission_matrix', 'edit', NULL));


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- New module + permissions exist
SELECT code, name, action
FROM   permissions
WHERE  code IN (
  'sec_permission_matrix.view',
  'sec_permission_matrix.edit'
)
ORDER  BY code;

-- Write policies now reference sec_permission_matrix
SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename IN ('permission_sets', 'permission_set_items', 'permission_set_assignments')
  AND  cmd IN ('INSERT','UPDATE','DELETE')
ORDER  BY tablename, cmd;

-- =============================================================================
-- END OF MIGRATION 149
--
-- BEHAVIOUR SUMMARY
-- ─────────────────
-- sec_permission_matrix.view  → access the Permission Matrix tab in the UI
-- sec_permission_matrix.edit  → write to permission_sets / _items / _assignments
-- sec_permission_catalog.view → read-only Permission Catalog tab
-- sec_permission_catalog.edit → no longer gates any RLS (retained for backward
--                               compatibility; effectively obsolete)
-- =============================================================================
