-- =============================================================================
-- Migration 134: Upgrade departments & department_heads RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- Both tables currently use has_permission() with granular department.*
-- codes (department.view, department.create, department.edit, department.delete,
-- department.manage_heads). These read from the dead role_permissions table
-- and have zero enforcement effect.
--
-- Migration 024 defined 6 granular department permissions. We consolidate
-- these into two Permission Matrix toggles:
--   departments.view  — read access to departments and department_heads
--   departments.edit  — full write access to both tables
--                       (replaces create/edit/delete/manage_heads granularity)
--
-- The `departments` module (sort_order 22) already exists. We seed the two
-- new permissions against it.
--
-- POLICIES CHANGED
-- ────────────────
--   departments:
--     departments_select  — has_permission('department.view')
--     departments_insert  — has_permission('department.create')
--     departments_update  — has_permission('department.edit')
--     departments_delete  — has_permission('department.delete')
--   department_heads:
--     department_heads_select  — has_permission('department.view')
--     department_heads_insert  — has_permission('department.manage_heads')
--     department_heads_update  — has_permission('department.manage_heads')
--     department_heads_delete  — has_permission('department.manage_heads')
-- =============================================================================


-- ── 1. Seed departments.view and departments.edit permissions ─────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT p.code, p.name, p.description, m.id, p.action
FROM (VALUES
  ('departments.view', 'View Departments',   'Grants read access to departments and department heads',  'view'),
  ('departments.edit', 'Manage Departments', 'Grants create / update / delete on departments and heads', 'edit')
) AS p(code, name, description, action)
JOIN modules m ON m.code = 'departments'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. departments ────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS departments_select ON departments;
DROP POLICY IF EXISTS departments_insert ON departments;
DROP POLICY IF EXISTS departments_update ON departments;
DROP POLICY IF EXISTS departments_delete ON departments;

CREATE POLICY departments_select ON departments FOR SELECT
  USING (
    deleted_at IS NULL
    AND user_can('departments', 'view', NULL)
  );

CREATE POLICY departments_insert ON departments FOR INSERT
  WITH CHECK (user_can('departments', 'edit', NULL));

CREATE POLICY departments_update ON departments FOR UPDATE
  USING      (user_can('departments', 'edit', NULL))
  WITH CHECK (user_can('departments', 'edit', NULL));

CREATE POLICY departments_delete ON departments FOR DELETE
  USING (user_can('departments', 'edit', NULL));


-- ── 3. department_heads ───────────────────────────────────────────────────────

DROP POLICY IF EXISTS department_heads_select ON department_heads;
DROP POLICY IF EXISTS department_heads_insert ON department_heads;
DROP POLICY IF EXISTS department_heads_update ON department_heads;
DROP POLICY IF EXISTS department_heads_delete ON department_heads;

CREATE POLICY department_heads_select ON department_heads FOR SELECT
  USING (user_can('departments', 'view', NULL));

CREATE POLICY department_heads_insert ON department_heads FOR INSERT
  WITH CHECK (user_can('departments', 'edit', NULL));

CREATE POLICY department_heads_update ON department_heads FOR UPDATE
  USING      (user_can('departments', 'edit', NULL))
  WITH CHECK (user_can('departments', 'edit', NULL));

CREATE POLICY department_heads_delete ON department_heads FOR DELETE
  USING (user_can('departments', 'edit', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('departments', 'department_heads')
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('departments.view', 'departments.edit')
ORDER  BY code;
