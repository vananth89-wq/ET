-- =============================================================================
-- Migration 082: RBP Phase 1 — Schema
--
-- WHAT THIS DOES
-- ══════════════
-- Lays the non-breaking schema additions that the new Role-Based Permission
-- (RBP) system needs.  Nothing here drops or changes existing tables/columns,
-- so the current has_permission() / module_registry RLS keeps working until
-- Phase 3 cuts over.
--
-- 1. target_groups        — named scopes (Self, Everyone, Direct L1, …).
--    target_group_members — pre-computed cache (populated by Phase 2 job).
--
-- 2. permissions.action   — nullable 'view'|'create'|'edit'|'delete'|'history'
--                           column added to the existing permissions table.
--                           Existing rows (expense.view_org etc.) stay untouched.
--
-- 3. role_permissions.target_group_id — nullable FK to target_groups.
--    Admin-module permissions leave it NULL; EV permissions carry a group id.
--
-- 4. workflow_steps.allow_edit — dual-control gate flag for
--    mid-flight approver edits.
--
-- 5. New module codes for EV + Admin modules added to the existing `modules`
--    table (EV = expense_reports, personal_info, …; Admin = departments, …).
--
-- 6. Action-based permissions seeded for every new module (one row per
--    module × action combination).
--
-- 7. System target groups seeded (idempotent).
--
-- NOTE: No role_permissions are seeded here.
--       All permission assignments are configured by the admin via the
--       Permission Matrix UI (Phase 4) before old policies are dropped (Phase 5).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. target_groups
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS target_groups (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text        UNIQUE NOT NULL,
  label        text        NOT NULL,
  scope_type   text        NOT NULL
    CHECK (scope_type IN (
      'self', 'everyone',
      'direct_l1', 'direct_l2',
      'same_department', 'same_country',
      'custom'
    )),
  filter_rules jsonb,
  is_system    boolean     NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  target_groups              IS 'Named employee scopes used to limit which records a role-permission applies to.';
COMMENT ON COLUMN target_groups.scope_type   IS 'Determines how membership is resolved: everyone/custom use the cache; others use live employee queries in user_can().';
COMMENT ON COLUMN target_groups.filter_rules IS 'Extra JSON criteria for custom scope_type rows.';
COMMENT ON COLUMN target_groups.is_system    IS 'System groups cannot be deleted via UI.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. target_group_members  (cache — populated by Phase 2 pg_cron job)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS target_group_members (
  group_id   uuid  NOT NULL REFERENCES target_groups (id) ON DELETE CASCADE,
  member_id  uuid  NOT NULL REFERENCES employees     (id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_tgm_member_group ON target_group_members (member_id, group_id);

COMMENT ON TABLE target_group_members IS
  'Pre-computed membership cache for each target_group. '
  'Only the ''everyone'' scope is populated here. '
  'All relational scopes (direct_l1, direct_l2, same_department, same_country) '
  'use live employee table queries inside user_can() instead. '
  'Truncated and rebuilt every 15 min by sync_target_group_members() pg_cron job.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. permissions.action  (nullable — existing rows stay intact)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE permissions
  ADD COLUMN IF NOT EXISTS action text
    CHECK (action IN ('view', 'create', 'edit', 'delete', 'history'));

COMMENT ON COLUMN permissions.action IS
  'Set only for new RBP action-based permissions (view/create/edit/delete/history). '
  'NULL on legacy flat-code permissions (expense.view_org, etc.).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. role_permissions.target_group_id  (nullable — existing rows stay intact)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE role_permissions
  ADD COLUMN IF NOT EXISTS target_group_id uuid
    REFERENCES target_groups (id) ON DELETE SET NULL;

COMMENT ON COLUMN role_permissions.target_group_id IS
  'NULL = admin-module permission (no scoping). '
  'Set = EV-module permission restricted to members of this target group.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. workflow_steps.allow_edit  (dual-control gate)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS allow_edit boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN workflow_steps.allow_edit IS
  'When true AND the acting user also holds edit permission, the approver '
  'may edit the record mid-flight (dual-control gate). Does NOT restart workflow.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. New module codes
-- ─────────────────────────────────────────────────────────────────────────────
-- EV (Employee-View) modules: target_group scoping required.
-- Admin modules: no scoping, target_group_id = NULL in role_permissions.

INSERT INTO modules (code, name, active, sort_order)
VALUES
  -- ── Employee-View modules ────────────────────────────────────────────────
  ('expense_reports',      'Expense Reports',         true, 10),
  ('personal_info',        'Personal Info',           true, 11),
  ('contact_info',         'Contact Info',            true, 12),
  ('employment',           'Employment Details',      true, 13),
  ('address',              'Address',                 true, 14),
  ('passport',             'Passport',                true, 15),
  ('identity_documents',   'Identity Documents',      true, 16),
  ('emergency_contacts',   'Emergency Contacts',      true, 17),
  ('org_chart',            'Org Chart',               true, 18),

  -- ── Admin modules ────────────────────────────────────────────────────────
  ('hire_employee',        'Hire Employee',           true, 20),
  ('employee_details',     'Employee Details (Admin)', true, 21),
  ('departments',          'Departments',             true, 22),
  ('picklists',            'Picklists',               true, 23),
  ('projects_mgmt',        'Projects',                true, 24),
  ('exchange_rates_mgmt',  'Exchange Rates',          true, 25),
  ('security_admin',       'Security & Roles',        true, 30),
  ('workflow_admin',       'Workflow Config',         true, 31),
  ('jobs_admin',           'Scheduled Jobs',          true, 32),
  ('reports_admin',        'Reports',                 true, 33)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Action-based permissions  (code = '<module>.<action>')
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  p.module_code || '.' || p.action  AS code,
  initcap(p.action) || ' ' || m.name AS name,
  p.description,
  m.id,
  p.action
FROM (VALUES
  -- ── expense_reports ───────────────────────────────────────────────────────
  ('expense_reports', 'view',    'View expense reports within the permitted scope'),
  ('expense_reports', 'create',  'Create a new expense report'),
  ('expense_reports', 'edit',    'Edit an expense report within the permitted scope'),
  ('expense_reports', 'delete',  'Delete a draft expense report'),
  ('expense_reports', 'history', 'View audit trail for expense reports'),

  -- ── personal_info ─────────────────────────────────────────────────────────
  ('personal_info',   'view',    'View personal information within the permitted scope'),
  ('personal_info',   'edit',    'Edit personal information'),

  -- ── contact_info ──────────────────────────────────────────────────────────
  ('contact_info',    'view',    'View contact information'),
  ('contact_info',    'edit',    'Edit contact information'),

  -- ── employment ────────────────────────────────────────────────────────────
  ('employment',      'view',    'View employment details'),
  ('employment',      'edit',    'Edit employment details'),

  -- ── address ───────────────────────────────────────────────────────────────
  ('address',         'view',    'View address records'),
  ('address',         'edit',    'Edit address records'),

  -- ── passport ──────────────────────────────────────────────────────────────
  ('passport',        'view',    'View passport details'),
  ('passport',        'edit',    'Edit passport details'),

  -- ── identity_documents ────────────────────────────────────────────────────
  ('identity_documents', 'view', 'View identity documents'),
  ('identity_documents', 'edit', 'Edit identity documents'),

  -- ── emergency_contacts ────────────────────────────────────────────────────
  ('emergency_contacts', 'view', 'View emergency contacts'),
  ('emergency_contacts', 'edit', 'Edit emergency contacts'),

  -- ── org_chart ─────────────────────────────────────────────────────────────
  ('org_chart',       'view',    'View the organisation chart'),

  -- ── hire_employee (Admin) ─────────────────────────────────────────────────
  ('hire_employee',   'create',  'Create and activate new employee records'),

  -- ── employee_details (Admin) ──────────────────────────────────────────────
  ('employee_details','view',    'View full employee details in admin panel'),
  ('employee_details','edit',    'Edit employee details in admin panel'),
  ('employee_details','delete',  'Soft-delete employee records'),

  -- ── departments (Admin) ───────────────────────────────────────────────────
  ('departments',     'view',    'View departments'),
  ('departments',     'create',  'Create departments'),
  ('departments',     'edit',    'Edit departments'),
  ('departments',     'delete',  'Delete departments'),

  -- ── picklists (Admin) ─────────────────────────────────────────────────────
  ('picklists',       'view',    'View picklists and values'),
  ('picklists',       'create',  'Create picklist values'),
  ('picklists',       'edit',    'Edit picklist values'),
  ('picklists',       'delete',  'Delete picklist values'),

  -- ── projects_mgmt (Admin) ─────────────────────────────────────────────────
  ('projects_mgmt',   'view',    'View projects'),
  ('projects_mgmt',   'create',  'Create projects'),
  ('projects_mgmt',   'edit',    'Edit projects'),
  ('projects_mgmt',   'delete',  'Delete projects'),

  -- ── exchange_rates_mgmt (Admin) ───────────────────────────────────────────
  ('exchange_rates_mgmt', 'view',   'View exchange rates'),
  ('exchange_rates_mgmt', 'create', 'Add exchange rate entries'),
  ('exchange_rates_mgmt', 'edit',   'Edit exchange rate entries'),
  ('exchange_rates_mgmt', 'delete', 'Delete exchange rate entries'),

  -- ── security_admin (Admin) ────────────────────────────────────────────────
  ('security_admin',  'view',    'View roles, permissions and assignments'),
  ('security_admin',  'edit',    'Manage roles and permission assignments'),

  -- ── workflow_admin (Admin) ────────────────────────────────────────────────
  ('workflow_admin',  'view',    'View workflow templates and instances'),
  ('workflow_admin',  'edit',    'Create and edit workflow templates'),

  -- ── jobs_admin (Admin) ────────────────────────────────────────────────────
  ('jobs_admin',      'view',    'View scheduled job runs and logs'),
  ('jobs_admin',      'edit',    'Enable / disable / trigger scheduled jobs'),

  -- ── reports_admin (Admin) ─────────────────────────────────────────────────
  ('reports_admin',   'view',    'Access the reports section'),
  ('reports_admin',   'create',  'Generate and export reports')

) AS p(module_code, action, description)
JOIN modules m ON m.code = p.module_code
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. System target groups
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO target_groups (code, label, scope_type, is_system)
VALUES
  ('self',            'Self (own records)',            'self',            true),
  ('everyone',        'All Employees',                 'everyone',        true),
  ('direct_l1',       'Direct Reports (L1)',           'direct_l1',       true),
  ('direct_l2',       'Team (Direct + Indirect, L2)',  'direct_l2',       true),
  ('same_department', 'Same Department',               'same_department', true),
  ('same_country',    'Same Country',                  'same_country',    true)
ON CONFLICT (code) DO UPDATE
  SET label = EXCLUDED.label, scope_type = EXCLUDED.scope_type;


-- ─────────────────────────────────────────────────────────────────────────────
-- Performance indexes for user_can() lookups
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_user_roles_profile_active2
  ON user_roles (profile_id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_rp_role_tg
  ON role_permissions (role_id, target_group_id);

CREATE INDEX IF NOT EXISTS idx_perm_module_action
  ON permissions (module_id, action)
  WHERE action IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_module_code2
  ON modules (code);


-- ─────────────────────────────────────────────────────────────────────────────
-- RLS on new tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE target_groups        ENABLE ROW LEVEL SECURITY;
ALTER TABLE target_group_members ENABLE ROW LEVEL SECURITY;

-- target_groups: admins manage, authenticated users can read (needed for Permission Matrix UI)
CREATE POLICY tg_select ON target_groups FOR SELECT USING (true);
CREATE POLICY tg_insert ON target_groups FOR INSERT WITH CHECK (has_role('admin'));
CREATE POLICY tg_update ON target_groups FOR UPDATE USING (has_role('admin'));
CREATE POLICY tg_delete ON target_groups FOR DELETE USING (
  has_role('admin') AND NOT is_system
);

-- target_group_members: populated by SECURITY DEFINER function only.
-- SELECT open so troubleshoot RPCs and user_can() debug tools can read it.
CREATE POLICY tgm_select ON target_group_members FOR SELECT USING (true);
CREATE POLICY tgm_insert ON target_group_members FOR INSERT
  WITH CHECK (has_role('admin'));
CREATE POLICY tgm_delete ON target_group_members FOR DELETE
  USING (has_role('admin'));


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'target_groups seeded' AS check, count(*) AS rows FROM target_groups;

SELECT 'action-based permissions seeded' AS check, count(*) AS rows
FROM   permissions
WHERE  action IS NOT NULL;

SELECT 'allow_edit column exists' AS check,
  column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_name  = 'workflow_steps'
  AND  column_name = 'allow_edit';

SELECT 'new modules seeded' AS check, code, name
FROM   modules
WHERE  code IN (
  'expense_reports', 'personal_info', 'org_chart',
  'hire_employee', 'security_admin', 'workflow_admin'
)
ORDER  BY sort_order;
