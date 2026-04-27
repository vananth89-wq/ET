-- =============================================================================
-- Employee RLS Update — align policies with new permission codes
--
-- Replaces legacy permission codes on existing employee-related tables:
--
--   employees
--     SELECT  employee.view / employee.view_all  →  employee.view_directory
--     UPDATE  (own OR employee.edit)             →  refined own-field check
--     DELETE  has_role('admin')                  →  employee.delete
--
--   employee_addresses
--   emergency_contacts
--   identity_records
--   passports
--     SELECT  own OR employee.edit_sensitive  →  own + view_own_<portlet> OR employee.edit
--     INSERT  own OR employee.edit_sensitive  →  own + edit_own_<portlet> OR employee.edit
--     UPDATE  own OR employee.edit_sensitive  →  own + edit_own_<portlet> OR employee.edit
--     DELETE  has_role('admin')               →  employee.edit
--
-- Depends on: 20260425021_employee_permissions.sql being run first
--             (view_own_* / edit_own_* codes must exist)
-- =============================================================================


-- ── Drop old employee policies ────────────────────────────────────────────────

DROP POLICY IF EXISTS employees_select  ON employees;
DROP POLICY IF EXISTS employees_insert  ON employees;
DROP POLICY IF EXISTS employees_update  ON employees;
DROP POLICY IF EXISTS employees_delete  ON employees;

DROP POLICY IF EXISTS employee_addresses_select ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_insert ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_update ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_delete ON employee_addresses;

DROP POLICY IF EXISTS emergency_contacts_select ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_insert ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_update ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_delete ON emergency_contacts;

DROP POLICY IF EXISTS identity_records_select ON identity_records;
DROP POLICY IF EXISTS identity_records_insert ON identity_records;
DROP POLICY IF EXISTS identity_records_update ON identity_records;
DROP POLICY IF EXISTS identity_records_delete ON identity_records;

DROP POLICY IF EXISTS passports_select ON passports;
DROP POLICY IF EXISTS passports_insert ON passports;
DROP POLICY IF EXISTS passports_update ON passports;
DROP POLICY IF EXISTS passports_delete ON passports;


-- ── EMPLOYEES (core table) ────────────────────────────────────────────────────
--
-- SELECT: employee.view_directory (all roles) covers the directory use-case.
--         Own record always visible so the logged-in employee can see themselves.
--
-- UPDATE: admin/HR use employee.edit for any record.
--         Self-service: own record + either edit_own_personal (name)
--         or edit_own_employment (employment fields, admin-only by default).
--
-- INSERT: employee.create (unchanged).
-- DELETE: employee.delete (replaces hard has_role('admin') guard).

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_permission('employee.view_directory')
      OR id = get_my_employee_id()
    )
  );

CREATE POLICY employees_insert ON employees FOR INSERT
  WITH CHECK (has_permission('employee.create'));

CREATE POLICY employees_update ON employees FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      id = get_my_employee_id() AND (
        has_permission('employee.edit_own_personal')    -- covers name field
        OR has_permission('employee.edit_own_employment') -- covers employment fields
      )
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      id = get_my_employee_id() AND (
        has_permission('employee.edit_own_personal')
        OR has_permission('employee.edit_own_employment')
      )
    )
  );

CREATE POLICY employees_delete ON employees FOR DELETE
  USING (has_permission('employee.delete'));


-- ── EMPLOYEE_ADDRESSES ────────────────────────────────────────────────────────
--
-- Pattern: own row + view_own_address (read) / edit_own_address (write)
--          OR employee.edit for admin/HR access to any employee's data.

CREATE POLICY employee_addresses_select ON employee_addresses FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_address')
    )
  );

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (has_permission('employee.edit'));


-- ── EMERGENCY_CONTACTS ────────────────────────────────────────────────────────

CREATE POLICY emergency_contacts_select ON emergency_contacts FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (has_permission('employee.edit'));


-- ── IDENTITY_RECORDS ──────────────────────────────────────────────────────────

CREATE POLICY identity_records_select ON identity_records FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_identity')
    )
  );

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (has_permission('employee.edit'));


-- ── PASSPORTS ─────────────────────────────────────────────────────────────────

CREATE POLICY passports_select ON passports FOR SELECT
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_passport')
    )
  );

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );

CREATE POLICY passports_update ON passports FOR UPDATE
  USING (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  )
  WITH CHECK (
    has_permission('employee.edit')
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (has_permission('employee.edit'));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT
  tablename,
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'employees', 'employee_addresses',
    'emergency_contacts', 'identity_records', 'passports'
  )
ORDER BY tablename, cmd;
