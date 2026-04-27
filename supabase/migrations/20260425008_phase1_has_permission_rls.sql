-- =============================================================================
-- Phase 1: has_permission() + Permission-Driven RLS
--
-- Makes the entire permission system truly dynamic — admin controls access
-- through the PermissionCatalog UI; the DB enforces it at the RLS layer.
--
-- Parts:
--   1. has_permission() function
--   2. get_my_permissions() function (ensure it exists)
--   3. Seed all modules
--   4. Seed all permission codes (aligned to frontend codes in App.tsx)
--   5. Rebuild full role_permissions matrix
--   6. Drop all existing RLS policies (clean slate)
--   7. Recreate all RLS policies using has_permission()
--
-- Security boundary:
--   System tables (roles, user_roles, modules, permissions, role_permissions)
--   remain guarded by has_role('admin') — these must never be accidentally
--   made reassignable through the UI.
-- =============================================================================


-- ── Part 1: has_permission() ──────────────────────────────────────────────────
--
-- Mirrors has_role() in design: STABLE + SECURITY DEFINER for per-query
-- evaluation and to bypass RLS on user_roles/role_permissions (no circular dep).

CREATE OR REPLACE FUNCTION has_permission(check_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles     ur
    JOIN   role_permissions rp ON rp.role_id      = ur.role_id
    JOIN   permissions     p  ON p.id             = rp.permission_id
    WHERE  ur.profile_id  = auth.uid()
      AND  p.code         = check_permission
      AND  ur.is_active   = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
  );
$$;

COMMENT ON FUNCTION has_permission(text) IS
  'Returns true if the current user holds the given permission code via any '
  'active role assignment. STABLE + SECURITY DEFINER: evaluated once per '
  'query, bypasses RLS on user_roles/role_permissions (no circular dependency).';


-- ── Part 2: get_my_permissions() ─────────────────────────────────────────────
--
-- Called by PermissionContext on login. Returns all distinct permission codes
-- for the current user, excluding expired role assignments.

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT p.code), '{}')
  FROM   user_roles     ur
  JOIN   role_permissions rp ON rp.role_id    = ur.role_id
  JOIN   permissions     p  ON p.id           = rp.permission_id
  WHERE  ur.profile_id  = auth.uid()
    AND  ur.is_active   = true
    AND  (ur.expires_at IS NULL OR ur.expires_at > now());
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes held by the current user. '
  'Called once on login by PermissionContext; cached client-side in a Set.';


-- ── Part 3: Seed modules ──────────────────────────────────────────────────────
--
-- Module codes align with the permission code prefixes (expense.*, employee.*).

INSERT INTO modules (code, name, active, sort_order)
VALUES
  ('expense',      'Expense Management', true, 1),
  ('employee',     'Employee',           true, 2),
  ('organization', 'Organization',       true, 3),
  ('reference',    'Reference Data',     true, 4),
  ('report',       'Reports',            true, 5),
  ('security',     'Security',           true, 6)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ── Part 4: Seed permission codes ────────────────────────────────────────────
--
-- Permission codes must match exactly what App.tsx ADMIN_NAV uses.
-- Frontend codes found in App.tsx (lines 67-93) are the source of truth.

INSERT INTO permissions (code, name, description, module_id)
SELECT p.code, p.name, p.description, m.id
FROM (VALUES
  -- ── Expense ─────────────────────────────────────────────────────────────
  ('expense', 'expense.create',        'Create Expense',
    'Raise a new expense report'),
  ('expense', 'expense.submit',        'Submit Expense',
    'Submit a draft report for approval'),
  ('expense', 'expense.view_own',      'View Own Expenses',
    'View own expense reports and their status'),
  ('expense', 'expense.edit',          'Edit Expense',
    'Edit own draft or rejected expense reports'),
  ('expense', 'expense.view_team',     'View Team Expenses',
    'View direct reports or department expense reports (submitted+)'),
  ('expense', 'expense.view_org',      'View All Expenses',
    'View all expense reports across the organisation'),
  ('expense', 'expense.edit_approval', 'Edit on Approval',
    'Edit expense data on the approval page (GL codes, notes, adjustments)'),
  ('expense', 'expense.export',        'Export Expenses',
    'Export expense data to CSV or PDF'),

  -- ── Employee ─────────────────────────────────────────────────────────────
  -- employee.view      → basic directory access (org chart, dropdowns) — all roles
  -- employee.view_all  → full admin employee management UI — HR, Admin
  ('employee', 'employee.view',           'View Employee Directory',
    'View basic employee profiles and org chart'),
  ('employee', 'employee.view_all',       'Manage Employees',
    'Access full employee management screens (admin panel)'),
  ('employee', 'employee.create',         'Create Employee',
    'Add a new employee record to the system'),
  ('employee', 'employee.edit',           'Edit Employee',
    'Edit core employee profile data'),
  ('employee', 'employee.edit_sensitive', 'Edit Sensitive Data',
    'View and edit addresses, emergency contacts, passport, identity records'),

  -- ── Organization ─────────────────────────────────────────────────────────
  ('organization', 'department.manage', 'Manage Departments',
    'Create, edit, delete departments and assign department heads'),

  -- ── Reference Data ───────────────────────────────────────────────────────
  ('reference', 'reference.manage',    'Manage Reference Data',
    'Create and edit picklists and picklist values'),
  ('reference', 'project.manage',      'Manage Projects',
    'Create, edit, activate and deactivate projects'),
  ('reference', 'exchange_rate.manage','Manage Exchange Rates',
    'Add and update currency exchange rates'),

  -- ── Reports ──────────────────────────────────────────────────────────────
  ('report', 'report.view',            'View Reports',
    'Access the reports section and view generated reports'),

  -- ── Security ─────────────────────────────────────────────────────────────
  ('security', 'security.manage_roles','Manage Roles & Permissions',
    'Access Role Assignments, Role Management, and Permission Catalog')

) AS p(module_code, code, name, description)
JOIN modules m ON m.code = p.module_code
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      module_id   = EXCLUDED.module_id;


-- ── Part 5: Rebuild full role_permissions matrix ──────────────────────────────
--
-- Default assignments. Admin can reassign any of these through the UI after
-- this migration runs — this is just the sane starting point.
--
-- Matrix summary:
--   ESS        → own expense lifecycle + basic employee/dept/reference view
--   Manager    → team expense view + approval editing + basic views
--   Dept Head  → same as manager (scope handled by RLS, not permissions)
--   Finance    → org expense view + approval + export + rates + reports
--   HR         → org expense view + approval + full employee mgmt + reports
--   Admin      → everything

TRUNCATE role_permissions;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  -- ── ESS ──────────────────────────────────────────────────────────────────
  ('ess', 'expense.create'),
  ('ess', 'expense.submit'),
  ('ess', 'expense.view_own'),
  ('ess', 'expense.edit'),
  ('ess', 'employee.view'),

  -- ── Manager ───────────────────────────────────────────────────────────────
  ('manager', 'expense.view_team'),
  ('manager', 'expense.edit_approval'),
  ('manager', 'employee.view'),

  -- ── Department Head ───────────────────────────────────────────────────────
  -- Same permissions as Manager — RLS scope functions differentiate the data
  ('dept_head', 'expense.view_team'),
  ('dept_head', 'expense.edit_approval'),
  ('dept_head', 'employee.view'),

  -- ── Finance ───────────────────────────────────────────────────────────────
  ('finance', 'expense.view_org'),
  ('finance', 'expense.edit_approval'),
  ('finance', 'expense.export'),
  ('finance', 'employee.view'),
  ('finance', 'reference.manage'),
  ('finance', 'exchange_rate.manage'),
  ('finance', 'report.view'),

  -- ── HR ────────────────────────────────────────────────────────────────────
  ('hr', 'expense.view_org'),
  ('hr', 'expense.edit_approval'),
  ('hr', 'employee.view'),
  ('hr', 'employee.view_all'),
  ('hr', 'employee.create'),
  ('hr', 'employee.edit'),
  ('hr', 'employee.edit_sensitive'),
  ('hr', 'department.manage'),
  ('hr', 'report.view'),

  -- ── Admin ─────────────────────────────────────────────────────────────────
  ('admin', 'expense.create'),
  ('admin', 'expense.submit'),
  ('admin', 'expense.view_own'),
  ('admin', 'expense.edit'),
  ('admin', 'expense.view_team'),
  ('admin', 'expense.view_org'),
  ('admin', 'expense.edit_approval'),
  ('admin', 'expense.export'),
  ('admin', 'employee.view'),
  ('admin', 'employee.view_all'),
  ('admin', 'employee.create'),
  ('admin', 'employee.edit'),
  ('admin', 'employee.edit_sensitive'),
  ('admin', 'department.manage'),
  ('admin', 'reference.manage'),
  ('admin', 'project.manage'),
  ('admin', 'exchange_rate.manage'),
  ('admin', 'report.view'),
  ('admin', 'security.manage_roles')

) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code;


-- ── Part 6: Drop ALL existing RLS policies (clean slate) ─────────────────────

DO $$
DECLARE rec RECORD;
BEGIN
  FOR rec IN
    SELECT schemaname, tablename, policyname
    FROM   pg_policies
    WHERE  schemaname = 'public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I',
      rec.policyname, rec.schemaname, rec.tablename);
  END LOOP;
END;
$$;


-- ── Part 7: Recreate all RLS policies (has_permission driven) ─────────────────
--
-- Rule:
--   Business logic gates  → has_permission('code')
--   System security gates → has_role('admin')   [roles, user_roles, etc.]
--   Own-data access       → get_my_employee_id() / auth.uid()


-- ── CURRENCIES ───────────────────────────────────────────────────────────────
CREATE POLICY currencies_select ON currencies FOR SELECT
  USING (has_permission('reference.manage') OR has_permission('exchange_rate.manage')
         OR auth.uid() IS NOT NULL);  -- everyone needs currency list for expense forms

CREATE POLICY currencies_insert ON currencies FOR INSERT
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY currencies_update ON currencies FOR UPDATE
  USING      (has_permission('reference.manage'))
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY currencies_delete ON currencies FOR DELETE
  USING (has_role('admin'));


-- ── EXCHANGE RATES ────────────────────────────────────────────────────────────
CREATE POLICY exchange_rates_select ON exchange_rates FOR SELECT
  USING (auth.uid() IS NOT NULL);  -- needed for expense line item rate lookup

CREATE POLICY exchange_rates_insert ON exchange_rates FOR INSERT
  WITH CHECK (has_permission('exchange_rate.manage'));

CREATE POLICY exchange_rates_update ON exchange_rates FOR UPDATE
  USING      (has_permission('exchange_rate.manage'))
  WITH CHECK (has_permission('exchange_rate.manage'));

CREATE POLICY exchange_rates_delete ON exchange_rates FOR DELETE
  USING (has_role('admin'));


-- ── PICKLISTS ─────────────────────────────────────────────────────────────────
CREATE POLICY picklists_select ON picklists FOR SELECT
  USING (auth.uid() IS NOT NULL);  -- needed for all dropdowns

CREATE POLICY picklists_insert ON picklists FOR INSERT
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY picklists_update ON picklists FOR UPDATE
  USING      (has_permission('reference.manage'))
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY picklists_delete ON picklists FOR DELETE
  USING (has_role('admin'));


-- ── PICKLIST VALUES ───────────────────────────────────────────────────────────
CREATE POLICY picklist_values_select ON picklist_values FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY picklist_values_insert ON picklist_values FOR INSERT
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY picklist_values_update ON picklist_values FOR UPDATE
  USING      (has_permission('reference.manage'))
  WITH CHECK (has_permission('reference.manage'));

CREATE POLICY picklist_values_delete ON picklist_values FOR DELETE
  USING (has_role('admin'));


-- ── PROJECTS ──────────────────────────────────────────────────────────────────
CREATE POLICY projects_select ON projects FOR SELECT
  USING (auth.uid() IS NOT NULL);  -- needed for expense line item project picker

CREATE POLICY projects_insert ON projects FOR INSERT
  WITH CHECK (has_permission('project.manage'));

CREATE POLICY projects_update ON projects FOR UPDATE
  USING      (has_permission('project.manage'))
  WITH CHECK (has_permission('project.manage'));

CREATE POLICY projects_delete ON projects FOR DELETE
  USING (has_role('admin'));


-- ── DEPARTMENTS ───────────────────────────────────────────────────────────────
CREATE POLICY departments_select ON departments FOR SELECT
  USING (deleted_at IS NULL AND auth.uid() IS NOT NULL);  -- needed for dropdowns/org chart

CREATE POLICY departments_insert ON departments FOR INSERT
  WITH CHECK (has_permission('department.manage'));

CREATE POLICY departments_update ON departments FOR UPDATE
  USING      (has_permission('department.manage'))
  WITH CHECK (has_permission('department.manage'));

CREATE POLICY departments_delete ON departments FOR DELETE
  USING (has_role('admin'));


-- ── DEPARTMENT HEADS ──────────────────────────────────────────────────────────
CREATE POLICY department_heads_select ON department_heads FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY department_heads_insert ON department_heads FOR INSERT
  WITH CHECK (has_permission('department.manage'));

CREATE POLICY department_heads_update ON department_heads FOR UPDATE
  USING      (has_permission('department.manage'))
  WITH CHECK (has_permission('department.manage'));

CREATE POLICY department_heads_delete ON department_heads FOR DELETE
  USING (has_role('admin'));


-- ── EMPLOYEES ─────────────────────────────────────────────────────────────────
-- employee.view     → basic directory (org chart, name lookups, dropdowns)
-- employee.view_all → full admin employee management screens
-- own record always visible regardless of permissions

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_permission('employee.view_all')
      OR has_permission('employee.view')
      OR id = get_my_employee_id()
    )
  );

CREATE POLICY employees_insert ON employees FOR INSERT
  WITH CHECK (has_permission('employee.create'));

CREATE POLICY employees_update ON employees FOR UPDATE
  USING      (id = get_my_employee_id() OR has_permission('employee.edit'))
  WITH CHECK (id = get_my_employee_id() OR has_permission('employee.edit'));

CREATE POLICY employees_delete ON employees FOR DELETE
  USING (has_role('admin'));


-- ── EMPLOYEE SUB-TABLES ───────────────────────────────────────────────────────
-- Own record always accessible; employee.edit_sensitive required for others.

CREATE POLICY employee_addresses_select ON employee_addresses FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (has_role('admin'));

CREATE POLICY emergency_contacts_select ON emergency_contacts FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY identity_records_select ON identity_records FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));

CREATE POLICY passports_select ON passports FOR SELECT
  USING (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY passports_update ON passports FOR UPDATE
  USING      (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'))
  WITH CHECK (employee_id = get_my_employee_id() OR has_permission('employee.edit_sensitive'));

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (employee_id = get_my_employee_id() OR has_role('admin'));


-- ── PROFILES ──────────────────────────────────────────────────────────────────
-- System table — own record + admin only.
CREATE POLICY profiles_select ON profiles FOR SELECT
  USING (id = auth.uid() OR has_role('admin'));

CREATE POLICY profiles_update ON profiles FOR UPDATE
  USING      (id = auth.uid() OR has_role('admin'))
  WITH CHECK (id = auth.uid() OR has_role('admin'));

CREATE POLICY profiles_delete ON profiles FOR DELETE
  USING (has_role('admin'));


-- ── ROLES ─────────────────────────────────────────────────────────────────────
-- System table — readable by all authenticated (dropdowns), admin manages.
CREATE POLICY roles_select ON roles FOR SELECT
  USING (auth.uid() IS NOT NULL AND active = true);

CREATE POLICY roles_insert ON roles FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY roles_update ON roles FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY roles_delete ON roles FOR DELETE
  USING (has_role('admin') AND is_system = false);


-- ── USER_ROLES ────────────────────────────────────────────────────────────────
-- System table — own rows readable (AuthContext), admin manages all.
CREATE POLICY user_roles_select ON user_roles FOR SELECT
  USING (profile_id = auth.uid() OR has_role('admin'));

CREATE POLICY user_roles_insert ON user_roles FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY user_roles_update ON user_roles FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY user_roles_delete ON user_roles FOR DELETE
  USING (has_role('admin'));


-- ── MODULES / PERMISSIONS / ROLE_PERMISSIONS ──────────────────────────────────
-- System tables — readable by all authenticated (PermissionCatalog screen).
-- Only admin can mutate — never permission-driven (would create a circular lock).
CREATE POLICY modules_select ON modules FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY modules_insert ON modules FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY modules_update ON modules FOR UPDATE
  USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY modules_delete ON modules FOR DELETE
  USING (has_role('admin'));

CREATE POLICY permissions_select ON permissions FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY permissions_insert ON permissions FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY permissions_update ON permissions FOR UPDATE
  USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY permissions_delete ON permissions FOR DELETE
  USING (has_role('admin'));

CREATE POLICY role_permissions_select ON role_permissions FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY role_permissions_insert ON role_permissions FOR INSERT
  WITH CHECK (has_role('admin'));

CREATE POLICY role_permissions_delete ON role_permissions FOR DELETE
  USING (has_role('admin'));


-- ── EXPENSE REPORTS ───────────────────────────────────────────────────────────
--
-- Visibility matrix:
--   expense.view_org   → all org, submitted+ (Finance, HR, Admin)
--   expense.view_team  → direct reports OR department, submitted+
--                        (Manager uses is_my_direct_report,
--                         Dept Head uses is_in_my_department,
--                         both covered by OR — whichever applies)
--   expense.view_own   → own reports only (ESS)
--   Admin              → everything including drafts

CREATE POLICY expense_reports_select ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_role('admin')
      OR (has_permission('expense.view_org')  AND status != 'draft')
      OR (has_permission('expense.view_team') AND status != 'draft'
          AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id)))
      OR (has_permission('expense.view_own')  AND employee_id = get_my_employee_id())
    )
  );

CREATE POLICY expense_reports_insert ON expense_reports FOR INSERT
  WITH CHECK (
    has_permission('expense.create')
    AND employee_id = get_my_employee_id()
  );

-- UPDATE:
--   Own draft/rejected → expense.edit
--   Team submitted+    → expense.view_team + expense.edit_approval (scoped)
--   Org submitted+     → expense.view_org  + expense.edit_approval
--   Admin              → anything
CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND employee_id = get_my_employee_id()
        AND status IN ('draft', 'rejected'))
    OR (has_permission('expense.view_org') AND has_permission('expense.edit_approval')
        AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_permission('expense.view_team') AND has_permission('expense.edit_approval')
        AND status IN ('submitted', 'approved', 'rejected')
        AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id)))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND employee_id = get_my_employee_id()
        AND status IN ('draft', 'rejected'))
    OR (has_permission('expense.view_org') AND has_permission('expense.edit_approval')
        AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_permission('expense.view_team') AND has_permission('expense.edit_approval')
        AND status IN ('submitted', 'approved', 'rejected')
        AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id)))
  );

CREATE POLICY expense_reports_delete ON expense_reports FOR DELETE
  USING (has_role('admin'));


-- ── LINE ITEMS ────────────────────────────────────────────────────────────────
CREATE POLICY line_items_select ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = line_items.report_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')  AND er.status != 'draft')
          OR (has_permission('expense.view_team') AND er.status != 'draft'
              AND (is_my_direct_report(er.employee_id) OR is_in_my_department(er.employee_id)))
          OR (has_permission('expense.view_own')  AND er.employee_id = get_my_employee_id())
        )
    )
  );

CREATE POLICY line_items_insert ON line_items FOR INSERT
  WITH CHECK (
    has_permission('expense.edit')
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id          = line_items.report_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM expense_reports er
          WHERE er.id          = line_items.report_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM expense_reports er
          WHERE er.id          = line_items.report_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  );

CREATE POLICY line_items_delete ON line_items FOR DELETE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM expense_reports er
          WHERE er.id          = line_items.report_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  );


-- ── ATTACHMENTS ───────────────────────────────────────────────────────────────
CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')  AND er.status != 'draft')
          OR (has_permission('expense.view_team') AND er.status != 'draft'
              AND (is_my_direct_report(er.employee_id) OR is_in_my_department(er.employee_id)))
          OR (has_permission('expense.view_own')  AND er.employee_id = get_my_employee_id())
        )
    )
  );

CREATE POLICY attachments_insert ON attachments FOR INSERT
  WITH CHECK (
    has_permission('expense.edit')
    AND EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY attachments_update ON attachments FOR UPDATE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM line_items li
          JOIN expense_reports er ON er.id = li.report_id
          WHERE li.id          = attachments.line_item_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM line_items li
          JOIN expense_reports er ON er.id = li.report_id
          WHERE li.id          = attachments.line_item_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  );

CREATE POLICY attachments_delete ON attachments FOR DELETE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
        AND EXISTS (
          SELECT 1 FROM line_items li
          JOIN expense_reports er ON er.id = li.report_id
          WHERE li.id          = attachments.line_item_id
            AND er.status      = 'draft'
            AND er.employee_id = get_my_employee_id()
        ))
  );


-- ── AUDIT LOG ─────────────────────────────────────────────────────────────────
-- Frontend writes directly via supabase.from('audit_log').insert() so
-- insert must allow any authenticated user (user_id = auth.uid() enforced at app layer).
CREATE POLICY audit_log_select ON audit_log FOR SELECT
  USING (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY audit_log_insert ON audit_log FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY audit_log_update ON audit_log FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY audit_log_delete ON audit_log FOR DELETE
  USING (has_role('admin'));


-- ── NOTIFICATIONS ─────────────────────────────────────────────────────────────
CREATE POLICY notifications_select ON notifications FOR SELECT
  USING (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY notifications_insert ON notifications FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY notifications_update ON notifications FOR UPDATE
  USING      (user_id = auth.uid() OR has_role('admin'))
  WITH CHECK (user_id = auth.uid() OR has_role('admin'));

CREATE POLICY notifications_delete ON notifications FOR DELETE
  USING (has_role('admin'));


-- ── WORKFLOW INSTANCES ────────────────────────────────────────────────────────
CREATE POLICY workflow_instances_select ON workflow_instances FOR SELECT
  USING (
    has_permission('expense.view_org')
    OR has_permission('expense.view_team')
  );

CREATE POLICY workflow_instances_insert ON workflow_instances FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY workflow_instances_update ON workflow_instances FOR UPDATE
  USING      (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY workflow_instances_delete ON workflow_instances FOR DELETE
  USING (has_role('admin'));


-- ── Verification ──────────────────────────────────────────────────────────────

-- Full permission matrix — confirm all roles have the right codes
SELECT
  m.name                                                          AS module,
  p.code                                                          AS permission,
  array_agg(r.code ORDER BY r.sort_order)
    FILTER (WHERE r.code IS NOT NULL)                             AS assigned_roles
FROM permissions p
JOIN modules m ON m.id = p.module_id
LEFT JOIN role_permissions rp ON rp.permission_id = p.id
LEFT JOIN roles r ON r.id = rp.role_id AND r.active = true
GROUP BY m.sort_order, m.name, p.code
ORDER BY m.sort_order, p.code;
