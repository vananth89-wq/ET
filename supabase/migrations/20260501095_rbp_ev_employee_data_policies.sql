-- =============================================================================
-- Migration 095: RBP — user_can() RLS for Employee-Data EV Modules
--
-- Replaces the flat has_permission('employee.edit') guards on all employee
-- satellite tables with user_can()-based policies so that target-group
-- population scoping applies consistently.
--
-- Tables upgraded (7 satellite tables):
--   employee_personal    ← module: personal_info
--   employee_contact     ← module: contact_info
--   employee_employment  ← module: employment
--   employee_addresses   ← module: address
--   emergency_contacts   ← module: emergency_contacts
--   identity_records     ← module: identity_documents
--   passports            ← module: passport
--
-- Policy pattern (same for every table)
-- ──────────────────────────────────────
--   SELECT  user_can('<module>', 'view', employee_id)
--           OR (self AND has_permission('<module>.view_own_*'))
--
--   INSERT  user_can('<module>', 'edit', employee_id)
--   WITH CHECK  OR (self AND has_permission('<module>.edit_own_*'))
--
--   UPDATE  user_can('<module>', 'edit', employee_id)
--           OR (self AND has_permission('<module>.edit_own_*'))
--
--   DELETE  user_can('<module>', 'edit', employee_id)
--           (no self-delete for HR data)
--
-- The self-service path (own-record) is unchanged from the previous policies.
-- The admin path changes from:
--   has_permission('employee.edit')              ← global, no scoping
-- to:
--   user_can('<module>', 'view|edit', employee_id) ← target-group aware
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. employee_personal  (module: personal_info)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ep_select ON employee_personal;
DROP POLICY IF EXISTS ep_insert ON employee_personal;
DROP POLICY IF EXISTS ep_update ON employee_personal;
DROP POLICY IF EXISTS ep_delete ON employee_personal;

CREATE POLICY ep_select ON employee_personal FOR SELECT
  USING (
    user_can('personal_info', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_personal')
    )
  );

CREATE POLICY ep_insert ON employee_personal FOR INSERT
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );

CREATE POLICY ep_update ON employee_personal FOR UPDATE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_personal')
    )
  );

CREATE POLICY ep_delete ON employee_personal FOR DELETE
  USING (user_can('personal_info', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. employee_contact  (module: contact_info)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ec_select ON employee_contact;
DROP POLICY IF EXISTS ec_insert ON employee_contact;
DROP POLICY IF EXISTS ec_update ON employee_contact;
DROP POLICY IF EXISTS ec_delete ON employee_contact;

CREATE POLICY ec_select ON employee_contact FOR SELECT
  USING (
    user_can('contact_info', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_contact')
    )
  );

CREATE POLICY ec_insert ON employee_contact FOR INSERT
  WITH CHECK (
    user_can('contact_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );

CREATE POLICY ec_update ON employee_contact FOR UPDATE
  USING (
    user_can('contact_info', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_contact')
    )
  );

CREATE POLICY ec_delete ON employee_contact FOR DELETE
  USING (user_can('contact_info', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. employee_employment  (module: employment)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS eem_select ON employee_employment;
DROP POLICY IF EXISTS eem_insert ON employee_employment;
DROP POLICY IF EXISTS eem_update ON employee_employment;
DROP POLICY IF EXISTS eem_delete ON employee_employment;

CREATE POLICY eem_select ON employee_employment FOR SELECT
  USING (
    user_can('employment', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_employment')
    )
  );

CREATE POLICY eem_insert ON employee_employment FOR INSERT
  WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  );

CREATE POLICY eem_update ON employee_employment FOR UPDATE
  USING (
    user_can('employment', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_employment')
    )
  );

CREATE POLICY eem_delete ON employee_employment FOR DELETE
  USING (user_can('employment', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. employee_addresses  (module: address)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS employee_addresses_select ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_insert ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_update ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_delete ON employee_addresses;

CREATE POLICY employee_addresses_select ON employee_addresses FOR SELECT
  USING (
    user_can('address', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_address')
    )
  );

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (
    user_can('address', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING (
    user_can('address', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_address')
    )
  );

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (user_can('address', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. emergency_contacts  (module: emergency_contacts)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS emergency_contacts_select ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_insert ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_update ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_delete ON emergency_contacts;

CREATE POLICY emergency_contacts_select ON emergency_contacts FOR SELECT
  USING (
    user_can('emergency_contacts', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_emergency')
    )
  );

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (user_can('emergency_contacts', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. identity_records  (module: identity_documents)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS identity_records_select ON identity_records;
DROP POLICY IF EXISTS identity_records_insert ON identity_records;
DROP POLICY IF EXISTS identity_records_update ON identity_records;
DROP POLICY IF EXISTS identity_records_delete ON identity_records;

CREATE POLICY identity_records_select ON identity_records FOR SELECT
  USING (
    user_can('identity_documents', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_identity')
    )
  );

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_identity')
    )
  );

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (user_can('identity_documents', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. passports  (module: passport)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS passports_select ON passports;
DROP POLICY IF EXISTS passports_insert ON passports;
DROP POLICY IF EXISTS passports_update ON passports;
DROP POLICY IF EXISTS passports_delete ON passports;

CREATE POLICY passports_select ON passports FOR SELECT
  USING (
    user_can('passport', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_own_passport')
    )
  );

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (
    user_can('passport', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );

CREATE POLICY passports_update ON passports FOR UPDATE
  USING (
    user_can('passport', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_own_passport')
    )
  );

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (user_can('passport', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  schemaname,
  tablename,
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE tablename IN (
  'employee_personal', 'employee_contact', 'employee_employment',
  'employee_addresses', 'emergency_contacts', 'identity_records', 'passports'
)
ORDER BY tablename, cmd;

-- =============================================================================
-- END OF MIGRATION 095
-- =============================================================================
