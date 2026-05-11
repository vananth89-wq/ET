-- =============================================================================
-- Migration 097: RBP — Add new permission rows
--
-- Adds the permission rows that were missing from the 082 seed:
--
--   hire_employee    → view, edit, delete, history
--                      (create was seeded in 082; adding the rest)
--
--   employee_details → history
--                      (view, edit, delete were seeded in 082)
--
--   inactive_employees (NEW module)
--                    → view, create, edit, delete, history
--                      Module represents the Inactive employee lifecycle state.
--                      Three lifecycle modules share the employees table:
--                        employee_details   → Active employees
--                        inactive_employees → Inactive employees
--                        hire_employee      → Draft / Incomplete employees
--
--   org_chart        (NEW module)
--                    → view  (feature gate only — no target group)
--
-- inactive_employees action semantics
-- ────────────────────────────────────
--   view    — see inactive employee records
--   create  — deactivate an employee (Active → Inactive)
--   edit    — change an inactive employee's status (e.g. Inactive → Active reactivation)
--   delete  — permanently remove an inactive employee record
--   history — view audit trail for inactive employee records
--
-- After this migration the Permission Matrix UI will render all three
-- Manage Employees rows and the Org Chart toggle without any frontend changes.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New modules
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES
  ('inactive_employees', 'Inactive Employees',  true, 25),
  ('org_chart',          'Org Chart',            true, 30)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. New permission rows
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  vals.module_code || '.' || vals.action  AS code,
  initcap(vals.action) || ' ' || m.name   AS name,
  vals.description,
  m.id AS module_id,
  vals.action
FROM (
  VALUES
    -- hire_employee — missing actions
    ('hire_employee', 'view',    'View hire pipeline (Draft/Incomplete employee records)'),
    ('hire_employee', 'edit',    'Edit draft employee records in the hire pipeline'),
    ('hire_employee', 'delete',  'Delete draft employee records from the hire pipeline'),
    ('hire_employee', 'history', 'View audit trail for hire pipeline records'),

    -- employee_details — missing history action
    ('employee_details', 'history', 'View audit trail for active employee records'),

    -- inactive_employees — all 5 actions (new module)
    ('inactive_employees', 'view',    'View inactive employee records'),
    ('inactive_employees', 'create',  'Deactivate an employee (Active → Inactive)'),
    ('inactive_employees', 'edit',    'Change an inactive employee''s status (e.g. reactivate)'),
    ('inactive_employees', 'delete',  'Permanently remove an inactive employee record'),
    ('inactive_employees', 'history', 'View audit trail for inactive employee records'),

    -- org_chart — feature gate (view only, no target group)
    ('org_chart', 'view', 'Access the Org Chart screen (feature on/off toggle — no target group)')

) AS vals(module_code, action, description)
JOIN modules m ON m.code = vals.module_code
ON CONFLICT (code) DO UPDATE
  SET description = EXCLUDED.description;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  m.code       AS module,
  p.action,
  p.code       AS permission_code
FROM   permissions p
JOIN   modules     m ON m.id = p.module_id
WHERE  m.code IN ('hire_employee', 'employee_details', 'inactive_employees', 'org_chart')
ORDER  BY m.sort_order, p.action;

-- =============================================================================
-- END OF MIGRATION 097
-- =============================================================================
