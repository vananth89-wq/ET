-- =============================================================================
-- Migration 147: Lookup permission separation + lookup views
--
-- DESIGN
-- ══════
-- Introduces dedicated lookup permissions separate from management permissions,
-- following the Phase 2 RBAC architecture:
--
--   entity_mgmt.*   → administrative screens (full table, all columns/rows)
--   entity.lookup   → transactional dropdowns (minimal columns, active rows only)
--
-- SCOPE
-- ─────
-- Four entities need transactional lookup access for expense workflows:
--
--   projects        Line item project coding
--   currencies      Expense base currency / line item currency
--   picklists       Expense category, payment method, and other dropdowns
--   departments     Department selection in transactional forms
--
-- WHAT THIS MIGRATION DOES
-- ────────────────────────
--   1. Seeds two new lightweight lookup modules: `projects`, `currencies`
--      (departments and picklists modules already exist from mig 082)
--
--   2. Seeds four lookup permissions:
--        projects.lookup     departments.lookup
--        currencies.lookup   picklists.lookup
--
--   3. Adds a _select_lookup RLS policy on each base table (additive OR policy —
--      does NOT touch existing management policies)
--
--   4. Creates four SECURITY INVOKER lookup views exposing minimal safe columns
--      with active/deleted_at filters baked in centrally
--
--   5. Assigns all four lookup permissions to the ESS permission set so every
--      employee can use transactional dropdowns
--
-- WHAT IS NOT TOUCHED
-- ───────────────────
--   Existing _select_mgmt / _insert / _update / _delete policies — unchanged
--   Management permissions (departments.view, reference.view, etc.) — unchanged
--   Admin / Finance / HR permission sets — they already have mgmt access
--   Frontend hooks — update separately after this migration is applied
--
-- RLS NOTE
-- ────────
-- PostgreSQL ORs multiple SELECT policies. Result per user:
--
--   Admin with mgmt.view   → existing mgmt policy fires → sees ALL rows/columns
--   Employee with .lookup  → new lookup policy fires    → sees active rows only
--                            View enforces column restriction
--   Neither                → both policies false         → zero rows
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 0: Expand permissions_action_check to allow 'lookup'
--
-- The original constraint (mig 082) only permits:
--   view | create | edit | delete | history
-- 'lookup' is a new action type introduced by this phase.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;

ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup'));


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Seed lookup-only modules
-- `departments` (22) and `picklists` (23) already exist from mig 082.
-- `projects` and `currencies` are new lightweight modules for lookup permissions.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES
  ('projects',   'Projects Lookup',   true, 37),
  ('currencies', 'Currencies Lookup', true, 38)
ON CONFLICT (code) DO UPDATE
  SET name       = EXCLUDED.name,
      sort_order = EXCLUDED.sort_order;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Seed lookup permissions
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT p.code, p.name, p.description, m.id, 'lookup'
FROM (VALUES
  ('projects.lookup',    'projects',    'Projects Lookup',
    'Read active project id and name for transactional dropdowns'),
  ('currencies.lookup',  'currencies',  'Currencies Lookup',
    'Read active currency id, code, name and symbol for dropdowns'),
  ('picklists.lookup',   'picklists',   'Picklists Lookup',
    'Read active picklist values for dropdowns and autocomplete'),
  ('departments.lookup', 'departments', 'Departments Lookup',
    'Read active department id and name for transactional forms')
) AS p(code, module_code, name, description)
JOIN modules m ON m.code = p.module_code
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Add lookup SELECT policies on base tables
-- These are ADDITIVE — existing management policies are not touched.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── projects ──────────────────────────────────────────────────────────────────
-- Existing mgmt policy: projects_select → user_can('projects_mgmt','view',NULL)
-- New lookup policy: active rows only

DROP POLICY IF EXISTS projects_select_lookup ON projects;
CREATE POLICY projects_select_lookup ON projects FOR SELECT
  USING (
    active = true
    AND user_can('projects', 'lookup', NULL)
  );


-- ── currencies ────────────────────────────────────────────────────────────────
-- Existing mgmt policy: currencies_select → user_can('exchange_rates_mgmt','view',NULL)
-- New lookup policy: active rows only

DROP POLICY IF EXISTS currencies_select_lookup ON currencies;
CREATE POLICY currencies_select_lookup ON currencies FOR SELECT
  USING (
    active = true
    AND user_can('currencies', 'lookup', NULL)
  );


-- ── picklists ─────────────────────────────────────────────────────────────────
-- Existing mgmt policy: picklists_select → user_can('reference','view',NULL)
-- New lookup policy: all rows (picklists have no active/deleted_at — they are
-- admin-managed categories, always valid. Row restriction lives on picklist_values.)
-- Required because vw_picklist_values_lookup JOINs picklists — SECURITY INVOKER
-- propagates the caller's identity, so RLS on picklists must also pass.

DROP POLICY IF EXISTS picklists_select_lookup ON picklists;
CREATE POLICY picklists_select_lookup ON picklists FOR SELECT
  USING (user_can('picklists', 'lookup', NULL));


-- ── picklist_values ───────────────────────────────────────────────────────────
-- Existing mgmt policy: picklist_values_select → user_can('reference','view',NULL)
-- New lookup policy: active values only

DROP POLICY IF EXISTS picklist_values_select_lookup ON picklist_values;
CREATE POLICY picklist_values_select_lookup ON picklist_values FOR SELECT
  USING (
    active = true
    AND user_can('picklists', 'lookup', NULL)
  );


-- ── departments ───────────────────────────────────────────────────────────────
-- Existing mgmt policy: departments_select → deleted_at IS NULL AND user_can('departments','view',NULL)
-- New lookup policy: non-deleted rows only (no active column on departments)

DROP POLICY IF EXISTS departments_select_lookup ON departments;
CREATE POLICY departments_select_lookup ON departments FOR SELECT
  USING (
    deleted_at IS NULL
    AND user_can('departments', 'lookup', NULL)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Create lookup views
--
-- All views use SECURITY INVOKER (Supabase default). The caller's identity is
-- passed through to base table RLS — the lookup policies above fire when the
-- view is queried. No SECURITY DEFINER required because no columns on these
-- tables are sensitive enough to require hard column-level enforcement.
--
-- Naming: vw_{entity}_lookup
-- Contract: id always included (FK storage), minimal display columns, no
--           audit fields, no internal metadata.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── vw_projects_lookup ────────────────────────────────────────────────────────
-- Used by: expense line item project coding dropdown
-- Columns: id (FK), name (display), start_date/end_date (date-aware filtering)
-- Hides: active, created_at, updated_at

CREATE OR REPLACE VIEW vw_projects_lookup AS
SELECT
  id,
  name,
  start_date,
  end_date
FROM  projects
WHERE active = true;

COMMENT ON VIEW vw_projects_lookup IS
  'Lookup view for projects. Exposes id + name of active projects only. '
  'No audit columns. Requires projects.lookup permission via base table RLS. '
  'Use this view for expense line item project dropdowns — never the base table.';


-- ── vw_currencies_lookup ──────────────────────────────────────────────────────
-- Used by: expense report base currency, line item currency selection
-- Columns: id (FK), code (ISO e.g. USD), name (US Dollar), symbol ($ ₹ ﷼)
-- Hides: active, created_at, updated_at

CREATE OR REPLACE VIEW vw_currencies_lookup AS
SELECT
  id,
  code,
  name,
  symbol
FROM  currencies
WHERE active = true;

COMMENT ON VIEW vw_currencies_lookup IS
  'Lookup view for currencies. Exposes id, ISO code, name, symbol of active '
  'currencies only. Requires currencies.lookup permission via base table RLS. '
  'Use this view for all currency dropdowns — never the base table.';


-- ── vw_picklist_values_lookup ─────────────────────────────────────────────────
-- Used by: expense category, payment method, and all other picklist dropdowns
-- Columns: id (FK), picklist_code (filter key e.g. EXPENSE_CATEGORY),
--          value (display label), ref_id (short code), parent_value_id (cascade)
-- Hides: picklist FK uuid, active, created_at, updated_at
--
-- Frontend usage:
--   supabase.from('vw_picklist_values_lookup')
--     .select('id, value')
--     .eq('picklist_code', 'EXPENSE_CATEGORY')
--     .order('value')
--
-- Note: picklist_code uses picklists.picklist_id (the TEXT code field),
-- not picklists.id (the UUID PK). This lets the frontend filter by a stable
-- human-readable key without knowing the picklist UUID.

CREATE OR REPLACE VIEW vw_picklist_values_lookup AS
SELECT
  pv.id,
  pl.picklist_id  AS picklist_code,   -- TEXT code e.g. 'EXPENSE_CATEGORY'
  pv.value,
  pv.ref_id,
  pv.parent_value_id                  -- supports cascading dropdowns (Country→State→City)
FROM  picklist_values pv
JOIN  picklists       pl ON pl.id = pv.picklist_id
WHERE pv.active = true;

COMMENT ON VIEW vw_picklist_values_lookup IS
  'Lookup view for picklist values. Filter by picklist_code (text key). '
  'Exposes id, value, ref_id, parent_value_id of active values only. '
  'Requires picklists.lookup permission via base table RLS on both tables. '
  'Use this view for all picklist dropdowns — never query picklist_values directly.';


-- ── vw_departments_lookup ─────────────────────────────────────────────────────
-- Used by: employee department selection in transactional forms
-- Columns: id (FK), dept_id (short code e.g. D001), name (display)
-- Hides: deleted_at, created_at, updated_at

CREATE OR REPLACE VIEW vw_departments_lookup AS
SELECT
  id,
  dept_id,
  name
FROM  departments
WHERE deleted_at IS NULL;

COMMENT ON VIEW vw_departments_lookup IS
  'Lookup view for departments. Exposes id, dept_id code, name of non-deleted '
  'departments only. Requires departments.lookup permission via base table RLS. '
  'Use this view for department dropdowns in transactional forms.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 5: Assign lookup permissions to ESS permission set
--
-- ESS = every employee. They need all four lookups to use transactional
-- screens (expense reports, line items, etc.)
-- Admin/Finance/HR already have mgmt access — they do not need lookup
-- permissions because the existing mgmt SELECT policies grant full access.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_set_items (permission_set_id, permission_id)
SELECT ps.id, p.id
FROM   permission_sets ps
CROSS  JOIN permissions p
WHERE  ps.name = 'ESS'
AND    p.code  IN (
  'projects.lookup',
  'currencies.lookup',
  'picklists.lookup',
  'departments.lookup'
)
ON CONFLICT DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. New modules
SELECT code, name, sort_order
FROM   modules
WHERE  code IN ('projects', 'currencies')
ORDER  BY sort_order;

-- 2. New permissions
SELECT p.code, p.name, p.action, m.code AS module_code
FROM   permissions p
JOIN   modules     m ON m.id = p.module_id
WHERE  p.code IN (
  'projects.lookup', 'currencies.lookup',
  'picklists.lookup', 'departments.lookup'
)
ORDER  BY p.code;

-- 3. Lookup policies exist alongside existing mgmt policies
SELECT tablename, policyname, cmd
FROM   pg_policies
WHERE  tablename IN ('projects', 'currencies', 'picklists', 'picklist_values', 'departments')
  AND  policyname LIKE '%lookup%'
ORDER  BY tablename, policyname;

-- 4. Views created
SELECT viewname
FROM   pg_views
WHERE  viewname IN (
  'vw_projects_lookup',
  'vw_currencies_lookup',
  'vw_picklist_values_lookup',
  'vw_departments_lookup'
)
ORDER  BY viewname;

-- 5. ESS permission set now includes all four lookup permissions
SELECT ps.name AS permission_set, p.code AS permission
FROM   permission_sets      ps
JOIN   permission_set_items psi ON psi.permission_set_id = ps.id
JOIN   permissions          p   ON p.id = psi.permission_id
WHERE  ps.name = 'ESS'
AND    p.code LIKE '%.lookup'
ORDER  BY p.code;

-- =============================================================================
-- END OF MIGRATION 147
--
-- AFTER THIS MIGRATION
-- ─────────────────────
-- 1. Run type regen:
--    npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--      > src/types/database.types.ts
--
-- 2. Update frontend hooks:
--    useProjects()       → add useProjectsLookup()  querying vw_projects_lookup
--    useExpenseData.ts   → switch project fetch to   vw_projects_lookup
--    (future)            → currency dropdowns use    vw_currencies_lookup
--    (future)            → picklist dropdowns use    vw_picklist_values_lookup
--    (future)            → department dropdowns use  vw_departments_lookup
--
-- PERMISSION SUMMARY AFTER THIS MIGRATION
-- ─────────────────────────────────────────
--   projects.lookup    → ESS (all employees) via PSA
--   currencies.lookup  → ESS (all employees) via PSA
--   picklists.lookup   → ESS (all employees) via PSA
--   departments.lookup → ESS (all employees) via PSA
--
--   Management access unchanged:
--     projects_mgmt.view/edit    → admin permission set
--     exchange_rates_mgmt.view/edit → admin/finance permission sets
--     reference.view/edit        → admin/hr/finance permission sets
--     departments.view/edit      → admin permission set
-- =============================================================================
