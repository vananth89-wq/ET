-- =============================================================================
-- Migration 101: Satellite self-service CREATE + DELETE
--
-- Adds self-service INSERT and DELETE paths to all 7 satellite table policies.
-- Before this migration, employees could only SELECT and UPDATE their own
-- satellite records (migration 095).  This migration adds:
--
--   INSERT  — employee can create their own satellite record (e.g. add a new
--             address, upload a passport) if they have the self-service
--             edit_own_* permission.
--
--   DELETE  — employee can delete their own satellite record (e.g. remove an
--             old address) if they have the self-service edit_own_* permission.
--             Admin delete path (user_can) already exists from migration 095.
--
-- The admin INSERT path is also added here for completeness — admins with the
-- appropriate user_can() edit permission can INSERT records on behalf of any
-- employee in their target group.
--
-- Self-service permission codes (has_permission checks):
--   employee.edit_own_personal     → employee_personal
--   employee.edit_own_contact      → employee_contact
--   employee.edit_own_employment   → employee_employment (read-only in ESS typically)
--   employee.edit_own_address      → employee_addresses
--   employee.edit_own_emergency    → emergency_contacts
--   employee.edit_own_identity     → identity_records
--   employee.edit_own_passport     → passports
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. employee_personal
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ep_insert ON employee_personal;
DROP POLICY IF EXISTS ep_delete ON employee_personal;

CREATE POLICY ep_insert ON employee_personal FOR INSERT
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );

CREATE POLICY ep_delete ON employee_personal FOR DELETE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. employee_contact
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ec_insert ON employee_contact;
DROP POLICY IF EXISTS ec_delete ON employee_contact;

CREATE POLICY ec_insert ON employee_contact FOR INSERT
  WITH CHECK (
    user_can('contact_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );

CREATE POLICY ec_delete ON employee_contact FOR DELETE
  USING (
    user_can('contact_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. employee_employment
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS eem_insert ON employee_employment;
DROP POLICY IF EXISTS eem_delete ON employee_employment;

CREATE POLICY eem_insert ON employee_employment FOR INSERT
  WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  );

CREATE POLICY eem_delete ON employee_employment FOR DELETE
  USING (
    user_can('employment', 'edit', employee_id)
    -- No self-service delete for employment records (HR-controlled)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. employee_addresses
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS employee_addresses_insert ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_delete ON employee_addresses;

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (
    user_can('address', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (
    user_can('address', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. emergency_contacts
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS emergency_contacts_insert ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_delete ON emergency_contacts;

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. identity_records
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS identity_records_insert ON identity_records;
DROP POLICY IF EXISTS identity_records_delete ON identity_records;

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. passports
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS passports_insert ON passports;
DROP POLICY IF EXISTS passports_delete ON passports;

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (
    user_can('passport', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (
    user_can('passport', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  tablename,
  policyname,
  cmd
FROM pg_policies
WHERE tablename IN (
  'employee_personal', 'employee_contact', 'employee_employment',
  'employee_addresses', 'emergency_contacts', 'identity_records', 'passports'
)
ORDER BY tablename, cmd;

-- =============================================================================
-- END OF MIGRATION 101
-- =============================================================================
