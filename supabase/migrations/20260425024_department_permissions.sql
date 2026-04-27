-- =============================================================================
-- Department Permission Set
--
-- Replaces the single coarse-grained department.manage permission with 7
-- granular codes aligned to the department UI portlets.
--
-- New permissions (organisation module):
--   department.view            View/browse departments — all roles (dropdowns etc.)
--   department.create          Create a new department
--   department.edit            Edit department details (name, description, parent)
--   department.delete          Soft-delete a department
--   department.manage_heads    Assign / remove department heads
--   department.view_members    View members belonging to a department
--   department.view_orgchart   View full department org chart (admin-level)
--
-- Retired: department.manage
--
-- RLS updates:
--   departments       SELECT → department.view
--                     INSERT → department.create
--                     UPDATE → department.edit
--                     DELETE → department.delete
--   department_heads  SELECT → department.view (everyone can see head info)
--                     INSERT/UPDATE → department.manage_heads
--                     DELETE → department.manage_heads
--
-- Run order: after 20260425021 (sort_order column on permissions exists).
-- =============================================================================


-- ── Part 1: Register permissions ─────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('department.view',          'View Departments',
    'Browse the department list and use department dropdowns across the app.',
    10),
  ('department.create',        'Create Department',
    'Add a new department to the organisation.',
    20),
  ('department.edit',          'Edit Department',
    'Edit department name, description, and parent department.',
    30),
  ('department.delete',        'Delete Department',
    'Soft-delete (deactivate) a department.',
    40),
  ('department.manage_heads',  'Assign Department Heads',
    'Assign or remove the head of a department.',
    50),
  ('department.view_members',  'View Department Members',
    'View the list of employees belonging to a department.',
    60),
  ('department.view_orgchart', 'View Department Org Chart',
    'View the full department org chart including hierarchy, heads and member counts.',
    70)
) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'organization'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- ── Part 2: Default role_permissions matrix ──────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES

  -- ── department.view → ALL roles ───────────────────────────────────────────
  ('admin',     'department.view'),
  ('finance',   'department.view'),
  ('hr',        'department.view'),
  ('manager',   'department.view'),
  ('dept_head', 'department.view'),
  ('ess',       'department.view'),

  -- ── department.create → admin, hr ────────────────────────────────────────
  ('admin', 'department.create'),
  ('hr',    'department.create'),

  -- ── department.edit → admin, hr ───────────────────────────────────────────
  ('admin', 'department.edit'),
  ('hr',    'department.edit'),

  -- ── department.delete → admin only ────────────────────────────────────────
  ('admin', 'department.delete'),

  -- ── department.manage_heads → admin, hr ───────────────────────────────────
  ('admin', 'department.manage_heads'),
  ('hr',    'department.manage_heads'),

  -- ── department.view_members → admin, hr, manager, dept_head ───────────────
  ('admin',     'department.view_members'),
  ('hr',        'department.view_members'),
  ('manager',   'department.view_members'),
  ('dept_head', 'department.view_members'),

  -- ── department.view_orgchart → admin, hr, manager, dept_head ──────────────
  ('admin',     'department.view_orgchart'),
  ('hr',        'department.view_orgchart'),
  ('manager',   'department.view_orgchart'),
  ('dept_head', 'department.view_orgchart')

) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── Part 3: Retire department.manage ─────────────────────────────────────────
-- Cascades to role_permissions automatically via FK ON DELETE CASCADE.

DELETE FROM permissions WHERE code = 'department.manage';


-- ── Part 4: Update RLS policies on departments and department_heads ───────────

DROP POLICY IF EXISTS departments_select ON departments;
DROP POLICY IF EXISTS departments_insert ON departments;
DROP POLICY IF EXISTS departments_update ON departments;
DROP POLICY IF EXISTS departments_delete ON departments;

DROP POLICY IF EXISTS department_heads_select ON department_heads;
DROP POLICY IF EXISTS department_heads_insert ON department_heads;
DROP POLICY IF EXISTS department_heads_update ON department_heads;
DROP POLICY IF EXISTS department_heads_delete ON department_heads;

-- departments
CREATE POLICY departments_select ON departments FOR SELECT
  USING (
    deleted_at IS NULL
    AND has_permission('department.view')
  );

CREATE POLICY departments_insert ON departments FOR INSERT
  WITH CHECK (has_permission('department.create'));

CREATE POLICY departments_update ON departments FOR UPDATE
  USING      (has_permission('department.edit'))
  WITH CHECK (has_permission('department.edit'));

CREATE POLICY departments_delete ON departments FOR DELETE
  USING (has_permission('department.delete'));

-- department_heads
-- Everyone with department.view can see who heads a department (org chart, dropdowns).
-- Only manage_heads can mutate.
CREATE POLICY department_heads_select ON department_heads FOR SELECT
  USING (has_permission('department.view'));

CREATE POLICY department_heads_insert ON department_heads FOR INSERT
  WITH CHECK (has_permission('department.manage_heads'));

CREATE POLICY department_heads_update ON department_heads FOR UPDATE
  USING      (has_permission('department.manage_heads'))
  WITH CHECK (has_permission('department.manage_heads'));

CREATE POLICY department_heads_delete ON department_heads FOR DELETE
  USING (has_permission('department.manage_heads'));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT
  p.code,
  p.name,
  p.sort_order,
  COALESCE(
    array_agg(r.code ORDER BY r.sort_order) FILTER (WHERE r.id IS NOT NULL),
    '{}'
  ) AS assigned_roles
FROM permissions p
LEFT JOIN role_permissions rp ON rp.permission_id = p.id
LEFT JOIN roles r ON r.id = rp.role_id
WHERE p.code LIKE 'department.%'
GROUP BY p.code, p.name, p.sort_order
ORDER BY p.sort_order;
