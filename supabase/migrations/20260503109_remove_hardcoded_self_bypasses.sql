-- =============================================================================
-- Migration 109: Remove hardcoded self-access bypasses
--
-- Principle: every RLS policy must be exactly two paths —
--   1. has_role('admin')          → handled inside user_can() Path A
--   2. user_can(module, action, id) → full matrix check (Path B/C/D)
--
-- No policy should contain `id = get_my_employee_id()` or
-- `has_permission('employee.*_own_*')` as a standalone bypass.
-- Those patterns skip the permission matrix and break admin UI control.
--
-- ESS self-access is still fully supported — user_can() Path C fires when
-- p_owner = caller's employee_id, checks the permission exists in their
-- role (with is_active + expires_at guards), and returns true.
-- The matrix controls whether that permission exists. No hardcoding.
--
-- Tables rewritten:
--   employees          (SELECT + UPDATE — migration 098 bypass removed)
--   employee_personal  (all 4 policies — migration 095/101 bypass removed)
--   employee_contact   (all 4 policies)
--   employee_employment(all 4 policies)
--   employee_addresses (all 4 policies)
--   emergency_contacts (all 4 policies)
--   identity_records   (all 4 policies)
--   passports          (all 4 policies)
--
-- Prerequisite: migration 110 must seed ESS permission set with
--   employee_details.view + all satellite module view/edit permissions
--   so Path C has something to find.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. employees  (core table — migration 098 bypass removed)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS employees_select ON employees;
DROP POLICY IF EXISTS employees_update ON employees;

-- SELECT: purely permission-driven, no own-record shortcut.
-- Path C in user_can() handles ESS seeing their own row provided
-- employee_details.view exists in their permission set.
CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      (status = 'Active'                    AND user_can('employee_details',   'view', id))
      OR (status = 'Inactive'               AND user_can('inactive_employees', 'view', id))
      OR (status IN ('Draft','Incomplete')  AND user_can('hire_employee',      'view', id))
    )
  );

-- UPDATE: ESS self-service goes through personal_info.edit — Path C
-- fires for own record and checks permission exists in the matrix.
-- Admin paths unchanged.
CREATE POLICY employees_update ON employees FOR UPDATE
  USING (
    -- ESS: own profile data (avatar, display name, etc.)
    -- Path C: p_owner = caller → checks personal_info.edit in their role
    user_can('personal_info', 'edit', id)

    -- Admin: edit active employee record
    OR (status = 'Active'                   AND user_can('employee_details',   'edit',   id))

    -- Deactivation: Active → Inactive
    OR (status = 'Active'                   AND user_can('inactive_employees', 'create', id))

    -- Reactivation: Inactive → Active
    OR (status = 'Inactive'                 AND user_can('inactive_employees', 'edit',   id))

    -- Hire pipeline: edit Draft / Incomplete record
    OR (status IN ('Draft','Incomplete')    AND user_can('hire_employee',      'edit',   id))
  )
  WITH CHECK (
    user_can('personal_info', 'edit', id)
    OR (status = 'Active'                   AND user_can('employee_details',   'edit',   id))
    OR (status = 'Active'                   AND user_can('inactive_employees', 'create', id))
    OR (status = 'Inactive'                 AND user_can('inactive_employees', 'edit',   id))
    OR (status IN ('Draft','Incomplete')    AND user_can('hire_employee',      'edit',   id))
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. employee_personal  (module: personal_info)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ep_select ON employee_personal;
DROP POLICY IF EXISTS ep_insert ON employee_personal;
DROP POLICY IF EXISTS ep_update ON employee_personal;
DROP POLICY IF EXISTS ep_delete ON employee_personal;

CREATE POLICY ep_select ON employee_personal FOR SELECT
  USING (user_can('personal_info', 'view', employee_id));

CREATE POLICY ep_insert ON employee_personal FOR INSERT
  WITH CHECK (user_can('personal_info', 'edit', employee_id));

CREATE POLICY ep_update ON employee_personal FOR UPDATE
  USING (user_can('personal_info', 'edit', employee_id))
  WITH CHECK (user_can('personal_info', 'edit', employee_id));

CREATE POLICY ep_delete ON employee_personal FOR DELETE
  USING (user_can('personal_info', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. employee_contact  (module: contact_info)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS ec_select ON employee_contact;
DROP POLICY IF EXISTS ec_insert ON employee_contact;
DROP POLICY IF EXISTS ec_update ON employee_contact;
DROP POLICY IF EXISTS ec_delete ON employee_contact;

CREATE POLICY ec_select ON employee_contact FOR SELECT
  USING (user_can('contact_info', 'view', employee_id));

CREATE POLICY ec_insert ON employee_contact FOR INSERT
  WITH CHECK (user_can('contact_info', 'edit', employee_id));

CREATE POLICY ec_update ON employee_contact FOR UPDATE
  USING (user_can('contact_info', 'edit', employee_id))
  WITH CHECK (user_can('contact_info', 'edit', employee_id));

CREATE POLICY ec_delete ON employee_contact FOR DELETE
  USING (user_can('contact_info', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. employee_employment  (module: employment)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS eem_select ON employee_employment;
DROP POLICY IF EXISTS eem_insert ON employee_employment;
DROP POLICY IF EXISTS eem_update ON employee_employment;
DROP POLICY IF EXISTS eem_delete ON employee_employment;

CREATE POLICY eem_select ON employee_employment FOR SELECT
  USING (user_can('employment', 'view', employee_id));

CREATE POLICY eem_insert ON employee_employment FOR INSERT
  WITH CHECK (user_can('employment', 'edit', employee_id));

CREATE POLICY eem_update ON employee_employment FOR UPDATE
  USING (user_can('employment', 'edit', employee_id))
  WITH CHECK (user_can('employment', 'edit', employee_id));

CREATE POLICY eem_delete ON employee_employment FOR DELETE
  USING (user_can('employment', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. employee_addresses  (module: address)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS employee_addresses_select ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_insert ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_update ON employee_addresses;
DROP POLICY IF EXISTS employee_addresses_delete ON employee_addresses;

CREATE POLICY employee_addresses_select ON employee_addresses FOR SELECT
  USING (user_can('address', 'view', employee_id));

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (user_can('address', 'edit', employee_id));

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING (user_can('address', 'edit', employee_id))
  WITH CHECK (user_can('address', 'edit', employee_id));

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (user_can('address', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. emergency_contacts  (module: emergency_contacts)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS emergency_contacts_select ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_insert ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_update ON emergency_contacts;
DROP POLICY IF EXISTS emergency_contacts_delete ON emergency_contacts;

CREATE POLICY emergency_contacts_select ON emergency_contacts FOR SELECT
  USING (user_can('emergency_contacts', 'view', employee_id));

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (user_can('emergency_contacts', 'edit', employee_id));

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING (user_can('emergency_contacts', 'edit', employee_id))
  WITH CHECK (user_can('emergency_contacts', 'edit', employee_id));

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (user_can('emergency_contacts', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. identity_records  (module: identity_documents)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS identity_records_select ON identity_records;
DROP POLICY IF EXISTS identity_records_insert ON identity_records;
DROP POLICY IF EXISTS identity_records_update ON identity_records;
DROP POLICY IF EXISTS identity_records_delete ON identity_records;

CREATE POLICY identity_records_select ON identity_records FOR SELECT
  USING (user_can('identity_documents', 'view', employee_id));

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (user_can('identity_documents', 'edit', employee_id));

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING (user_can('identity_documents', 'edit', employee_id))
  WITH CHECK (user_can('identity_documents', 'edit', employee_id));

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (user_can('identity_documents', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. passports  (module: passport)
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS passports_select ON passports;
DROP POLICY IF EXISTS passports_insert ON passports;
DROP POLICY IF EXISTS passports_update ON passports;
DROP POLICY IF EXISTS passports_delete ON passports;

CREATE POLICY passports_select ON passports FOR SELECT
  USING (user_can('passport', 'view', employee_id));

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (user_can('passport', 'edit', employee_id));

CREATE POLICY passports_update ON passports FOR UPDATE
  USING (user_can('passport', 'edit', employee_id))
  WITH CHECK (user_can('passport', 'edit', employee_id));

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (user_can('passport', 'edit', employee_id));


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  tablename,
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE tablename IN (
  'employees',
  'employee_personal', 'employee_contact', 'employee_employment',
  'employee_addresses', 'emergency_contacts', 'identity_records', 'passports'
)
ORDER BY tablename, cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 109
--
-- NEXT: Run migration 110 to seed ESS permission set with all module
-- permissions required for Path C to grant self-access through the matrix.
-- Without 110, ESS employees will be locked out of their own data.
-- =============================================================================
