-- =============================================================================
-- Migration : 20260419002_rls_policies.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-19
-- Description: Row Level Security policies for all tables.
--              All access is dynamic — driven by profile_roles table.
--              Admin role is superuser and always wins.
--              Idempotent: DROP IF EXISTS before every CREATE POLICY.
-- =============================================================================


-- =============================================================================
-- HELPER FUNCTIONS
-- Written once, used in every policy.
-- SECURITY DEFINER = runs as function owner, bypasses RLS on internal lookups.
-- This prevents infinite recursion when policies query profile_roles.
-- =============================================================================

CREATE OR REPLACE FUNCTION has_role(check_role role_type)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM profile_roles
    WHERE profile_id = auth.uid()
    AND   role       = check_role
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

CREATE OR REPLACE FUNCTION has_any_role(check_roles role_type[])
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM profile_roles
    WHERE profile_id = auth.uid()
    AND   role       = ANY(check_roles)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

CREATE OR REPLACE FUNCTION get_my_employee_id()
RETURNS UUID AS $$
  SELECT employee_id FROM profiles WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

CREATE OR REPLACE FUNCTION is_my_direct_report(emp_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id         = emp_id
    AND   manager_id = get_my_employee_id()
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;


-- =============================================================================
-- DROP EXISTING POLICIES (safe to re-run)
-- =============================================================================

-- profiles
DROP POLICY IF EXISTS "profiles_select"  ON profiles;
DROP POLICY IF EXISTS "profiles_update"  ON profiles;
DROP POLICY IF EXISTS "profiles_delete"  ON profiles;

-- profile_roles
DROP POLICY IF EXISTS "profile_roles_select" ON profile_roles;
DROP POLICY IF EXISTS "profile_roles_insert" ON profile_roles;
DROP POLICY IF EXISTS "profile_roles_update" ON profile_roles;
DROP POLICY IF EXISTS "profile_roles_delete" ON profile_roles;

-- departments
DROP POLICY IF EXISTS "departments_select" ON departments;
DROP POLICY IF EXISTS "departments_insert" ON departments;
DROP POLICY IF EXISTS "departments_update" ON departments;
DROP POLICY IF EXISTS "departments_delete" ON departments;

-- department_heads
DROP POLICY IF EXISTS "department_heads_select" ON department_heads;
DROP POLICY IF EXISTS "department_heads_insert" ON department_heads;
DROP POLICY IF EXISTS "department_heads_update" ON department_heads;
DROP POLICY IF EXISTS "department_heads_delete" ON department_heads;

-- employees
DROP POLICY IF EXISTS "employees_select" ON employees;
DROP POLICY IF EXISTS "employees_insert" ON employees;
DROP POLICY IF EXISTS "employees_update" ON employees;
DROP POLICY IF EXISTS "employees_delete" ON employees;

-- employee_addresses
DROP POLICY IF EXISTS "employee_addresses_select" ON employee_addresses;
DROP POLICY IF EXISTS "employee_addresses_insert" ON employee_addresses;
DROP POLICY IF EXISTS "employee_addresses_update" ON employee_addresses;
DROP POLICY IF EXISTS "employee_addresses_delete" ON employee_addresses;

-- emergency_contacts
DROP POLICY IF EXISTS "emergency_contacts_select" ON emergency_contacts;
DROP POLICY IF EXISTS "emergency_contacts_insert" ON emergency_contacts;
DROP POLICY IF EXISTS "emergency_contacts_update" ON emergency_contacts;
DROP POLICY IF EXISTS "emergency_contacts_delete" ON emergency_contacts;

-- identity_records
DROP POLICY IF EXISTS "identity_records_select" ON identity_records;
DROP POLICY IF EXISTS "identity_records_insert" ON identity_records;
DROP POLICY IF EXISTS "identity_records_update" ON identity_records;
DROP POLICY IF EXISTS "identity_records_delete" ON identity_records;

-- passports
DROP POLICY IF EXISTS "passports_select" ON passports;
DROP POLICY IF EXISTS "passports_insert" ON passports;
DROP POLICY IF EXISTS "passports_update" ON passports;
DROP POLICY IF EXISTS "passports_delete" ON passports;

-- currencies
DROP POLICY IF EXISTS "currencies_select" ON currencies;
DROP POLICY IF EXISTS "currencies_insert" ON currencies;
DROP POLICY IF EXISTS "currencies_update" ON currencies;
DROP POLICY IF EXISTS "currencies_delete" ON currencies;

-- exchange_rates
DROP POLICY IF EXISTS "exchange_rates_select" ON exchange_rates;
DROP POLICY IF EXISTS "exchange_rates_insert" ON exchange_rates;
DROP POLICY IF EXISTS "exchange_rates_update" ON exchange_rates;
DROP POLICY IF EXISTS "exchange_rates_delete" ON exchange_rates;

-- picklists
DROP POLICY IF EXISTS "picklists_select" ON picklists;
DROP POLICY IF EXISTS "picklists_insert" ON picklists;
DROP POLICY IF EXISTS "picklists_update" ON picklists;
DROP POLICY IF EXISTS "picklists_delete" ON picklists;

-- picklist_values
DROP POLICY IF EXISTS "picklist_values_select" ON picklist_values;
DROP POLICY IF EXISTS "picklist_values_insert" ON picklist_values;
DROP POLICY IF EXISTS "picklist_values_update" ON picklist_values;
DROP POLICY IF EXISTS "picklist_values_delete" ON picklist_values;

-- projects
DROP POLICY IF EXISTS "projects_select" ON projects;
DROP POLICY IF EXISTS "projects_insert" ON projects;
DROP POLICY IF EXISTS "projects_update" ON projects;
DROP POLICY IF EXISTS "projects_delete" ON projects;

-- expense_reports
DROP POLICY IF EXISTS "expense_reports_select" ON expense_reports;
DROP POLICY IF EXISTS "expense_reports_insert" ON expense_reports;
DROP POLICY IF EXISTS "expense_reports_update" ON expense_reports;
DROP POLICY IF EXISTS "expense_reports_delete" ON expense_reports;

-- line_items
DROP POLICY IF EXISTS "line_items_select" ON line_items;
DROP POLICY IF EXISTS "line_items_insert" ON line_items;
DROP POLICY IF EXISTS "line_items_update" ON line_items;
DROP POLICY IF EXISTS "line_items_delete" ON line_items;

-- attachments
DROP POLICY IF EXISTS "attachments_select" ON attachments;
DROP POLICY IF EXISTS "attachments_insert" ON attachments;
DROP POLICY IF EXISTS "attachments_update" ON attachments;
DROP POLICY IF EXISTS "attachments_delete" ON attachments;

-- workflow_instances
DROP POLICY IF EXISTS "workflow_instances_select" ON workflow_instances;
DROP POLICY IF EXISTS "workflow_instances_insert" ON workflow_instances;
DROP POLICY IF EXISTS "workflow_instances_update" ON workflow_instances;
DROP POLICY IF EXISTS "workflow_instances_delete" ON workflow_instances;

-- notifications
DROP POLICY IF EXISTS "notifications_select" ON notifications;
DROP POLICY IF EXISTS "notifications_insert" ON notifications;
DROP POLICY IF EXISTS "notifications_update" ON notifications;
DROP POLICY IF EXISTS "notifications_delete" ON notifications;

-- audit_log
DROP POLICY IF EXISTS "audit_log_select" ON audit_log;
DROP POLICY IF EXISTS "audit_log_insert" ON audit_log;


-- =============================================================================
-- AUTH DOMAIN
-- =============================================================================

-- ─── PROFILES ────────────────────────────────────────────────────────────────
CREATE POLICY "profiles_select"
  ON profiles FOR SELECT
  USING ( id = auth.uid() OR has_role('admin') );

CREATE POLICY "profiles_update"
  ON profiles FOR UPDATE
  USING      ( id = auth.uid() OR has_role('admin') )
  WITH CHECK ( id = auth.uid() OR has_role('admin') );

CREATE POLICY "profiles_delete"
  ON profiles FOR DELETE
  USING ( has_role('admin') );


-- ─── PROFILE ROLES ───────────────────────────────────────────────────────────
CREATE POLICY "profile_roles_select"
  ON profile_roles FOR SELECT
  USING ( profile_id = auth.uid() OR has_role('admin') );

CREATE POLICY "profile_roles_insert"
  ON profile_roles FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "profile_roles_update"
  ON profile_roles FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "profile_roles_delete"
  ON profile_roles FOR DELETE
  USING ( has_role('admin') );


-- =============================================================================
-- ORGANISATION DOMAIN
-- =============================================================================

-- ─── DEPARTMENTS ─────────────────────────────────────────────────────────────
CREATE POLICY "departments_select"
  ON departments FOR SELECT
  USING ( auth.uid() IS NOT NULL AND deleted_at IS NULL );

CREATE POLICY "departments_insert"
  ON departments FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "departments_update"
  ON departments FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "departments_delete"
  ON departments FOR DELETE
  USING ( has_role('admin') );


-- ─── DEPARTMENT HEADS ────────────────────────────────────────────────────────
CREATE POLICY "department_heads_select"
  ON department_heads FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "department_heads_insert"
  ON department_heads FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "department_heads_update"
  ON department_heads FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "department_heads_delete"
  ON department_heads FOR DELETE
  USING ( has_role('admin') );


-- ─── EMPLOYEES ───────────────────────────────────────────────────────────────
CREATE POLICY "employees_select"
  ON employees FOR SELECT
  USING (
    has_role('admin')
    OR (
      deleted_at IS NULL AND (
        id = get_my_employee_id()
        OR is_my_direct_report(id)
        OR has_any_role(ARRAY['finance']::role_type[])
      )
    )
  );

CREATE POLICY "employees_insert"
  ON employees FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "employees_update"
  ON employees FOR UPDATE
  USING      ( id = get_my_employee_id() OR has_role('admin') )
  WITH CHECK ( id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "employees_delete"
  ON employees FOR DELETE
  USING ( has_role('admin') );


-- ─── EMPLOYEE ADDRESSES ──────────────────────────────────────────────────────
CREATE POLICY "employee_addresses_select"
  ON employee_addresses FOR SELECT
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "employee_addresses_insert"
  ON employee_addresses FOR INSERT
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "employee_addresses_update"
  ON employee_addresses FOR UPDATE
  USING      ( employee_id = get_my_employee_id() OR has_role('admin') )
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "employee_addresses_delete"
  ON employee_addresses FOR DELETE
  USING ( has_role('admin') );


-- ─── EMERGENCY CONTACTS ──────────────────────────────────────────────────────
CREATE POLICY "emergency_contacts_select"
  ON emergency_contacts FOR SELECT
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "emergency_contacts_insert"
  ON emergency_contacts FOR INSERT
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "emergency_contacts_update"
  ON emergency_contacts FOR UPDATE
  USING      ( employee_id = get_my_employee_id() OR has_role('admin') )
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "emergency_contacts_delete"
  ON emergency_contacts FOR DELETE
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );


-- ─── IDENTITY RECORDS ────────────────────────────────────────────────────────
CREATE POLICY "identity_records_select"
  ON identity_records FOR SELECT
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "identity_records_insert"
  ON identity_records FOR INSERT
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "identity_records_update"
  ON identity_records FOR UPDATE
  USING      ( employee_id = get_my_employee_id() OR has_role('admin') )
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "identity_records_delete"
  ON identity_records FOR DELETE
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );


-- ─── PASSPORTS ───────────────────────────────────────────────────────────────
CREATE POLICY "passports_select"
  ON passports FOR SELECT
  USING ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "passports_insert"
  ON passports FOR INSERT
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "passports_update"
  ON passports FOR UPDATE
  USING      ( employee_id = get_my_employee_id() OR has_role('admin') )
  WITH CHECK ( employee_id = get_my_employee_id() OR has_role('admin') );

CREATE POLICY "passports_delete"
  ON passports FOR DELETE
  USING ( has_role('admin') );


-- =============================================================================
-- REFERENCE DATA DOMAIN
-- Everyone can read. Finance/Admin can write. Admin can delete.
-- =============================================================================

-- ─── CURRENCIES ──────────────────────────────────────────────────────────────
CREATE POLICY "currencies_select"
  ON currencies FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "currencies_insert"
  ON currencies FOR INSERT
  WITH CHECK ( has_any_role(ARRAY['finance', 'admin']::role_type[]) );

CREATE POLICY "currencies_update"
  ON currencies FOR UPDATE
  USING      ( has_any_role(ARRAY['finance', 'admin']::role_type[]) )
  WITH CHECK ( has_any_role(ARRAY['finance', 'admin']::role_type[]) );

CREATE POLICY "currencies_delete"
  ON currencies FOR DELETE
  USING ( has_role('admin') );


-- ─── EXCHANGE RATES ──────────────────────────────────────────────────────────
CREATE POLICY "exchange_rates_select"
  ON exchange_rates FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "exchange_rates_insert"
  ON exchange_rates FOR INSERT
  WITH CHECK ( has_any_role(ARRAY['finance', 'admin']::role_type[]) );

CREATE POLICY "exchange_rates_update"
  ON exchange_rates FOR UPDATE
  USING      ( has_any_role(ARRAY['finance', 'admin']::role_type[]) )
  WITH CHECK ( has_any_role(ARRAY['finance', 'admin']::role_type[]) );

CREATE POLICY "exchange_rates_delete"
  ON exchange_rates FOR DELETE
  USING ( has_role('admin') );


-- ─── PICKLISTS ───────────────────────────────────────────────────────────────
CREATE POLICY "picklists_select"
  ON picklists FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "picklists_insert"
  ON picklists FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "picklists_update"
  ON picklists FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "picklists_delete"
  ON picklists FOR DELETE
  USING ( has_role('admin') );


-- ─── PICKLIST VALUES ─────────────────────────────────────────────────────────
CREATE POLICY "picklist_values_select"
  ON picklist_values FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "picklist_values_insert"
  ON picklist_values FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "picklist_values_update"
  ON picklist_values FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "picklist_values_delete"
  ON picklist_values FOR DELETE
  USING ( has_role('admin') );


-- ─── PROJECTS ────────────────────────────────────────────────────────────────
CREATE POLICY "projects_select"
  ON projects FOR SELECT
  USING ( auth.uid() IS NOT NULL );

CREATE POLICY "projects_insert"
  ON projects FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "projects_update"
  ON projects FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "projects_delete"
  ON projects FOR DELETE
  USING ( has_role('admin') );


-- =============================================================================
-- EXPENSE DOMAIN
-- =============================================================================

-- ─── EXPENSE REPORTS ─────────────────────────────────────────────────────────
CREATE POLICY "expense_reports_select"
  ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      has_role('admin')
      OR (has_role('finance') AND status != 'draft')
      OR (has_role('manager') AND status != 'draft' AND is_my_direct_report(employee_id))
      OR employee_id = get_my_employee_id()
    )
  );

CREATE POLICY "expense_reports_insert"
  ON expense_reports FOR INSERT
  WITH CHECK ( employee_id = get_my_employee_id() );

CREATE POLICY "expense_reports_update"
  ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_role('finance') AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_role('manager') AND status IN ('submitted', 'approved', 'rejected') AND is_my_direct_report(employee_id))
    OR (employee_id = get_my_employee_id() AND status = 'draft')
  )
  WITH CHECK (
    has_role('admin')
    OR (has_role('finance') AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_role('manager') AND status IN ('submitted', 'approved', 'rejected') AND is_my_direct_report(employee_id))
    OR (employee_id = get_my_employee_id() AND status = 'draft')
  );

CREATE POLICY "expense_reports_delete"
  ON expense_reports FOR DELETE
  USING (
    has_role('admin')
    OR (employee_id = get_my_employee_id() AND status = 'draft')
  );


-- ─── LINE ITEMS ──────────────────────────────────────────────────────────────
CREATE POLICY "line_items_select"
  ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = line_items.report_id
        AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance') AND er.status != 'draft')
          OR (has_role('manager') AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY "line_items_insert"
  ON line_items FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY "line_items_update"
  ON line_items FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY "line_items_delete"
  ON line_items FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );


-- ─── ATTACHMENTS ─────────────────────────────────────────────────────────────
CREATE POLICY "attachments_select"
  ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id = attachments.line_item_id
        AND  er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance') AND er.status != 'draft')
          OR (has_role('manager') AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY "attachments_insert"
  ON attachments FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.status   = 'draft'
        AND  er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY "attachments_update"
  ON attachments FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.status   = 'draft'
        AND  er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.status   = 'draft'
        AND  er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY "attachments_delete"
  ON attachments FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.status   = 'draft'
        AND  er.employee_id = get_my_employee_id()
    )
  );


-- =============================================================================
-- WORKFLOW DOMAIN (placeholder)
-- =============================================================================

CREATE POLICY "workflow_instances_select"
  ON workflow_instances FOR SELECT
  USING ( has_any_role(ARRAY['manager', 'finance', 'admin']::role_type[]) );

CREATE POLICY "workflow_instances_insert"
  ON workflow_instances FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "workflow_instances_update"
  ON workflow_instances FOR UPDATE
  USING      ( has_role('admin') )
  WITH CHECK ( has_role('admin') );

CREATE POLICY "workflow_instances_delete"
  ON workflow_instances FOR DELETE
  USING ( has_role('admin') );


-- =============================================================================
-- NOTIFICATIONS DOMAIN (placeholder)
-- =============================================================================

CREATE POLICY "notifications_select"
  ON notifications FOR SELECT
  USING ( user_id = auth.uid() OR has_role('admin') );

CREATE POLICY "notifications_insert"
  ON notifications FOR INSERT
  WITH CHECK ( has_role('admin') );

CREATE POLICY "notifications_update"
  ON notifications FOR UPDATE
  USING      ( user_id = auth.uid() OR has_role('admin') )
  WITH CHECK ( user_id = auth.uid() OR has_role('admin') );

CREATE POLICY "notifications_delete"
  ON notifications FOR DELETE
  USING ( user_id = auth.uid() OR has_role('admin') );


-- =============================================================================
-- AUDIT DOMAIN — append-only, no UPDATE or DELETE
-- =============================================================================

CREATE POLICY "audit_log_select"
  ON audit_log FOR SELECT
  USING ( user_id = auth.uid() OR has_role('admin') );

CREATE POLICY "audit_log_insert"
  ON audit_log FOR INSERT
  WITH CHECK ( auth.uid() IS NOT NULL );

-- NO UPDATE policy — audit log is immutable by design.
-- NO DELETE policy — audit log is immutable by design.


-- =============================================================================
-- BOOTSTRAP NOTE
-- After running this migration, create your first user via Supabase dashboard:
--   Authentication → Users → Add user → Create new user
-- Then run in SQL Editor to grant admin access:
--
--   INSERT INTO profile_roles (profile_id, role, assigned_by)
--   SELECT id, 'admin',    id FROM auth.users WHERE email = 'your@email.com';
--   INSERT INTO profile_roles (profile_id, role, assigned_by)
--   SELECT id, 'employee', id FROM auth.users WHERE email = 'your@email.com';
-- =============================================================================
