-- =============================================================================
-- Migration 220: Fix satellite table RLS — hire pipeline Path B
--
-- ROOT CAUSE
-- ──────────
-- All satellite table RLS policies pass employee_id as p_owner to user_can(),
-- triggering Path D, which requires the record to be in the
-- target_group_members cache. Newly created Draft/Incomplete/Pending employees
-- are never pre-loaded into that cache, so every satellite INSERT/SELECT/UPDATE
-- returns 403 Forbidden for the hire pipeline.
--
-- FIX — dual permission + Path B for hire-pipeline records
-- ─────────────────────────────────────────────────────────
-- Each policy keeps its existing Path D check (scoped, cache-based) PLUS a
-- second OR branch that fires only for hire-pipeline records:
--
--   user_can('<module>', '<action>', employee_id)    ← Path D (active employees)
--   OR (
--     user_can('<module>', '<action>', NULL)          ← Path B: section permission
--     AND user_can('hire_employee', 'view/edit', NULL)  ← Path B: hire pipeline access
--     AND EXISTS (parent employee is Draft/Incomplete/Pending)
--   )
--
-- WHY TWO PERMISSIONS IN THE OR BRANCH
-- ──────────────────────────────────────
-- Path B (p_owner=NULL) checks only whether the permission exists in any role
-- — it ignores scope_type. ESS employees have self-scoped satellite permissions
-- (e.g. personal_info.view), so user_can('personal_info','view',NULL) returns
-- true for every employee in the company, not just HR staff. Without a second
-- guard, every ESS user would satisfy the OR branch and could read/write draft
-- hire records.
--
-- Adding AND user_can('hire_employee','view/edit',NULL) closes the gap:
-- that permission is only granted to HR roles, never to ESS. Both permissions
-- must be present for the OR branch to open.
--
-- This also preserves full matrix control:
--   • Remove personal_info.view  → blocks section access for active AND draft
--   • Remove hire_employee.view  → blocks all hire pipeline visibility entirely
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
-- • Active employee satellite access is unchanged (still Path D, target-scoped)
-- • ESS self-service is unchanged (personal_info.edit self-scope, Path D)
-- • The permission matrix UI fully controls both branches
--
-- TABLES AFFECTED
-- ───────────────
--   employee_personal   (personal_info)
--   employee_contact    (contact_info)
--   employee_employment (employment)
--   employee_addresses  (address)
--   emergency_contacts  (emergency_contacts)
--   identity_records    (identity_documents)
--   passports           (passport)
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
      user_can('personal_info',  'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ep_insert ON employee_personal FOR INSERT
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ep_update ON employee_personal FOR UPDATE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ep_delete ON employee_personal FOR DELETE
  USING (
    user_can('personal_info', 'edit', employee_id)
    OR (
      user_can('personal_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_personal.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('contact_info',  'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_contact.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ec_insert ON employee_contact FOR INSERT
  WITH CHECK (
    user_can('contact_info', 'edit', employee_id)
    OR (
      user_can('contact_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_contact.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ec_update ON employee_contact FOR UPDATE
  USING (
    user_can('contact_info', 'edit', employee_id)
    OR (
      user_can('contact_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_contact.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('contact_info', 'edit', employee_id)
    OR (
      user_can('contact_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_contact.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ec_delete ON employee_contact FOR DELETE
  USING (
    user_can('contact_info', 'edit', employee_id)
    OR (
      user_can('contact_info',  'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_contact.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('employment',    'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eem_insert ON employee_employment FOR INSERT
  WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eem_update ON employee_employment FOR UPDATE
  USING (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eem_delete ON employee_employment FOR DELETE
  USING (
    user_can('employment', 'edit', employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_employment.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('address',       'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_addresses.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY employee_addresses_insert ON employee_addresses FOR INSERT
  WITH CHECK (
    user_can('address', 'edit', employee_id)
    OR (
      user_can('address',       'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_addresses.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY employee_addresses_update ON employee_addresses FOR UPDATE
  USING (
    user_can('address', 'edit', employee_id)
    OR (
      user_can('address',       'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_addresses.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('address', 'edit', employee_id)
    OR (
      user_can('address',       'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_addresses.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY employee_addresses_delete ON employee_addresses FOR DELETE
  USING (
    user_can('address', 'edit', employee_id)
    OR (
      user_can('address',       'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_addresses.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('emergency_contacts', 'view', NULL)
      AND user_can('hire_employee',  'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = emergency_contacts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY emergency_contacts_insert ON emergency_contacts FOR INSERT
  WITH CHECK (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      user_can('emergency_contacts', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = emergency_contacts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY emergency_contacts_update ON emergency_contacts FOR UPDATE
  USING (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      user_can('emergency_contacts', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = emergency_contacts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      user_can('emergency_contacts', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = emergency_contacts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY emergency_contacts_delete ON emergency_contacts FOR DELETE
  USING (
    user_can('emergency_contacts', 'edit', employee_id)
    OR (
      user_can('emergency_contacts', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = emergency_contacts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('identity_documents', 'view', NULL)
      AND user_can('hire_employee',  'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = identity_records.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY identity_records_insert ON identity_records FOR INSERT
  WITH CHECK (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      user_can('identity_documents', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = identity_records.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY identity_records_update ON identity_records FOR UPDATE
  USING (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      user_can('identity_documents', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = identity_records.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      user_can('identity_documents', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = identity_records.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY identity_records_delete ON identity_records FOR DELETE
  USING (
    user_can('identity_documents', 'edit', employee_id)
    OR (
      user_can('identity_documents', 'edit', NULL)
      AND user_can('hire_employee',  'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = identity_records.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


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
      user_can('passport',      'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = passports.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY passports_insert ON passports FOR INSERT
  WITH CHECK (
    user_can('passport', 'edit', employee_id)
    OR (
      user_can('passport',      'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = passports.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY passports_update ON passports FOR UPDATE
  USING (
    user_can('passport', 'edit', employee_id)
    OR (
      user_can('passport',      'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = passports.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('passport', 'edit', employee_id)
    OR (
      user_can('passport',      'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = passports.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY passports_delete ON passports FOR DELETE
  USING (
    user_can('passport', 'edit', employee_id)
    OR (
      user_can('passport',      'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = passports.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM   pg_policies
WHERE  tablename IN (
  'employee_personal', 'employee_contact', 'employee_employment',
  'employee_addresses', 'emergency_contacts', 'identity_records', 'passports'
)
ORDER BY tablename, cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 220
--
-- Run order: 217 → 218 → 219 → 220 → 221
--
-- OR branch access matrix:
--   ESS employee        personal_info.view (self) + NO hire_employee.view → BLOCKED ✓
--   HR Analyst          personal_info.view (everyone) + hire_employee.view → ALLOWED ✓
--   HR Analyst (no pp)  NO passport.view + hire_employee.view             → BLOCKED ✓
--   Remove hire perm    any satellite perm + NO hire_employee.view        → BLOCKED ✓
-- =============================================================================
