-- =============================================================================
-- Reference Data, Project, and Exchange Rate permission sets
--
-- Replaces three coarse-grained .manage permissions with 4 granular CRUD codes
-- each, grouped as separate sections in the permission grid.
--
-- New permissions (reference module):
--   Reference Data: reference.view, reference.create, reference.edit, reference.delete
--   Projects:       project.view,   project.create,   project.edit,   project.delete
--   Exchange Rates: exchange_rate.view, exchange_rate.create, exchange_rate.edit, exchange_rate.delete
--
-- Retired: reference.manage, project.manage, exchange_rate.manage
--
-- RLS tables updated:
--   picklists, picklist_values  → reference.*
--   projects                    → project.*
--   currencies, exchange_rates  → exchange_rate.*
--
-- Run order: after 20260425024 (department permissions).
-- =============================================================================


-- ── Part 1: Register permissions ─────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES

  -- Reference Data
  ('reference.view',       'View Reference Data',    'Browse picklists and their values.',                  10),
  ('reference.create',     'Create Reference Entry', 'Add new picklists or picklist values.',               20),
  ('reference.edit',       'Edit Reference Entry',   'Edit picklist names, descriptions and values.',       30),
  ('reference.delete',     'Delete Reference Entry', 'Delete picklists or picklist values.',                40),

  -- Projects
  ('project.view',         'View Projects',          'View the project list (required for expense coding).', 50),
  ('project.create',       'Create Project',         'Add a new project.',                                  60),
  ('project.edit',         'Edit Project',           'Edit project name, code and details.',                70),
  ('project.delete',       'Delete Project',         'Delete a project.',                                   80),

  -- Exchange Rates
  ('exchange_rate.view',   'View Exchange Rates',    'View currencies and their exchange rates.',            90),
  ('exchange_rate.create', 'Add Exchange Rate',      'Add a new currency or exchange rate entry.',          100),
  ('exchange_rate.edit',   'Edit Exchange Rate',     'Update currency details or exchange rate values.',    110),
  ('exchange_rate.delete', 'Delete Exchange Rate',   'Remove a currency or exchange rate entry.',           120)

) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'reference'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- ── Part 2: Default role_permissions matrix ──────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES

  -- ── reference.view → ALL roles (picklist dropdowns used everywhere) ───────
  ('admin',     'reference.view'),
  ('finance',   'reference.view'),
  ('hr',        'reference.view'),
  ('manager',   'reference.view'),
  ('dept_head', 'reference.view'),
  ('ess',       'reference.view'),

  -- ── reference.create → admin, hr ─────────────────────────────────────────
  ('admin', 'reference.create'),
  ('hr',    'reference.create'),

  -- ── reference.edit → admin, hr, finance ──────────────────────────────────
  ('admin',   'reference.edit'),
  ('hr',      'reference.edit'),
  ('finance', 'reference.edit'),

  -- ── reference.delete → admin only ────────────────────────────────────────
  ('admin', 'reference.delete'),

  -- ── project.view → ALL roles (used in expense coding) ───────────────────
  ('admin',     'project.view'),
  ('finance',   'project.view'),
  ('hr',        'project.view'),
  ('manager',   'project.view'),
  ('dept_head', 'project.view'),
  ('ess',       'project.view'),

  -- ── project.create → admin, finance, manager ─────────────────────────────
  ('admin',   'project.create'),
  ('finance', 'project.create'),
  ('manager', 'project.create'),

  -- ── project.edit → admin, finance, manager ───────────────────────────────
  ('admin',   'project.edit'),
  ('finance', 'project.edit'),
  ('manager', 'project.edit'),

  -- ── project.delete → admin only ──────────────────────────────────────────
  ('admin', 'project.delete'),

  -- ── exchange_rate.view → admin, finance, hr, manager, dept_head ──────────
  ('admin',     'exchange_rate.view'),
  ('finance',   'exchange_rate.view'),
  ('hr',        'exchange_rate.view'),
  ('manager',   'exchange_rate.view'),
  ('dept_head', 'exchange_rate.view'),

  -- ── exchange_rate.create → admin, finance ────────────────────────────────
  ('admin',   'exchange_rate.create'),
  ('finance', 'exchange_rate.create'),

  -- ── exchange_rate.edit → admin, finance ──────────────────────────────────
  ('admin',   'exchange_rate.edit'),
  ('finance', 'exchange_rate.edit'),

  -- ── exchange_rate.delete → admin only ────────────────────────────────────
  ('admin', 'exchange_rate.delete')

) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── Part 3: Retire coarse-grained permissions ─────────────────────────────────
-- FK ON DELETE CASCADE removes associated role_permissions automatically.

DELETE FROM permissions
WHERE code IN ('reference.manage', 'project.manage', 'exchange_rate.manage');


-- ── Part 4: Update RLS policies ───────────────────────────────────────────────

-- picklists -------------------------------------------------------------------
DROP POLICY IF EXISTS picklists_select ON picklists;
DROP POLICY IF EXISTS picklists_insert ON picklists;
DROP POLICY IF EXISTS picklists_update ON picklists;
DROP POLICY IF EXISTS picklists_delete ON picklists;

CREATE POLICY picklists_select ON picklists FOR SELECT
  USING (has_permission('reference.view'));

CREATE POLICY picklists_insert ON picklists FOR INSERT
  WITH CHECK (has_permission('reference.create'));

CREATE POLICY picklists_update ON picklists FOR UPDATE
  USING      (has_permission('reference.edit'))
  WITH CHECK (has_permission('reference.edit'));

CREATE POLICY picklists_delete ON picklists FOR DELETE
  USING (has_permission('reference.delete'));

-- picklist_values -------------------------------------------------------------
DROP POLICY IF EXISTS picklist_values_select ON picklist_values;
DROP POLICY IF EXISTS picklist_values_insert ON picklist_values;
DROP POLICY IF EXISTS picklist_values_update ON picklist_values;
DROP POLICY IF EXISTS picklist_values_delete ON picklist_values;

CREATE POLICY picklist_values_select ON picklist_values FOR SELECT
  USING (has_permission('reference.view'));

CREATE POLICY picklist_values_insert ON picklist_values FOR INSERT
  WITH CHECK (has_permission('reference.create'));

CREATE POLICY picklist_values_update ON picklist_values FOR UPDATE
  USING      (has_permission('reference.edit'))
  WITH CHECK (has_permission('reference.edit'));

CREATE POLICY picklist_values_delete ON picklist_values FOR DELETE
  USING (has_permission('reference.delete'));

-- projects --------------------------------------------------------------------
DROP POLICY IF EXISTS projects_select ON projects;
DROP POLICY IF EXISTS projects_insert ON projects;
DROP POLICY IF EXISTS projects_update ON projects;
DROP POLICY IF EXISTS projects_delete ON projects;

CREATE POLICY projects_select ON projects FOR SELECT
  USING (has_permission('project.view'));

CREATE POLICY projects_insert ON projects FOR INSERT
  WITH CHECK (has_permission('project.create'));

CREATE POLICY projects_update ON projects FOR UPDATE
  USING      (has_permission('project.edit'))
  WITH CHECK (has_permission('project.edit'));

CREATE POLICY projects_delete ON projects FOR DELETE
  USING (has_permission('project.delete'));

-- currencies ------------------------------------------------------------------
DROP POLICY IF EXISTS currencies_select ON currencies;
DROP POLICY IF EXISTS currencies_insert ON currencies;
DROP POLICY IF EXISTS currencies_update ON currencies;
DROP POLICY IF EXISTS currencies_delete ON currencies;

CREATE POLICY currencies_select ON currencies FOR SELECT
  USING (has_permission('exchange_rate.view'));

CREATE POLICY currencies_insert ON currencies FOR INSERT
  WITH CHECK (has_permission('exchange_rate.create'));

CREATE POLICY currencies_update ON currencies FOR UPDATE
  USING      (has_permission('exchange_rate.edit'))
  WITH CHECK (has_permission('exchange_rate.edit'));

CREATE POLICY currencies_delete ON currencies FOR DELETE
  USING (has_permission('exchange_rate.delete'));

-- exchange_rates --------------------------------------------------------------
DROP POLICY IF EXISTS exchange_rates_select ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_insert ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_update ON exchange_rates;
DROP POLICY IF EXISTS exchange_rates_delete ON exchange_rates;

CREATE POLICY exchange_rates_select ON exchange_rates FOR SELECT
  USING (has_permission('exchange_rate.view'));

CREATE POLICY exchange_rates_insert ON exchange_rates FOR INSERT
  WITH CHECK (has_permission('exchange_rate.create'));

CREATE POLICY exchange_rates_update ON exchange_rates FOR UPDATE
  USING      (has_permission('exchange_rate.edit'))
  WITH CHECK (has_permission('exchange_rate.edit'));

CREATE POLICY exchange_rates_delete ON exchange_rates FOR DELETE
  USING (has_permission('exchange_rate.delete'));


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
WHERE p.code LIKE 'reference.%'
   OR p.code LIKE 'project.%'
   OR p.code LIKE 'exchange_rate.%'
GROUP BY p.code, p.name, p.sort_order
ORDER BY p.sort_order;
