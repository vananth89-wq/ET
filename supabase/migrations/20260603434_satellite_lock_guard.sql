-- =============================================================================
-- Migration 434 — Lock satellite writes when employees.locked = true
-- =============================================================================
--
-- Supersedes 432 (satellite_lock_guard) and 433 (satellite_lock_guard).
-- 432 failed because it referenced employee_dependents, which was not yet in
-- the remote DB. 433 was a duplicate with a different (less clean) approach.
--
-- DESIGN
-- ──────
-- The guard is placed inside the existing Path B EXISTS subquery:
--
--   Path B (hire pipeline):
--     user_can('<module>', 'edit', NULL)
--     AND user_can('hire_employee', 'edit', NULL)
--     AND EXISTS (
--       SELECT 1 FROM employees e
--       WHERE  e.id         = <table>.employee_id
--         AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
--         AND  e.locked     = false                          ← ADDED
--         AND  e.deleted_at IS NULL
--     )
--
-- Path A (target-group-scoped) is left unchanged. HR Head users with
-- edit_all_pending always reach records via Path A (user_can resolves them
-- through the target-group cache), so no explicit exemption is needed.
--
-- TABLES COVERED (7 tables, 14 policies):
--   employee_personal    ep_insert, ep_update          (Path B → locked = false)
--   employee_contact     ec_insert, ec_update          (Path B → locked = false)
--   employee_employment  eem_insert, eem_update        (Path B → locked = false)
--   employee_addresses   employee_addresses_insert/update (Path B → locked = false)
--   emergency_contacts   emergency_contacts_insert/update (Path B → locked = false)
--   identity_records     identity_records_insert/update   (Path B → locked = false)
--   passports            passports_insert, passports_update (Path B → locked = false)
--
-- DEFERRED (tables not yet on remote DB):
--   employee_dependents  — covered in a later migration once mig 289 is applied
--   employee_education   — covered in the same later migration
--
-- BLAST-RADIUS AUDIT
-- ──────────────────
-- ✓ Active employees (locked = false) — EXISTS returns true → no change
-- ✓ Draft / Incomplete (locked = false) — passes through, behaviour unchanged
-- ✓ Pending (locked = true):
--     - Regular HR Analyst (Path B) → blocked ✓
--     - HR Head / edit_all_pending (Path A) → allowed ✓
-- ✓ Rejected (locked reset to false by mig 269) → passes through
-- ✓ SECURITY DEFINER RPCs — bypass RLS entirely, unaffected
-- =============================================================================


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. employee_personal
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS ep_insert ON employee_personal;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS ep_update ON employee_personal;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. employee_contact
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS ec_insert ON employee_contact;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS ec_update ON employee_contact;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. employee_employment
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS eem_insert ON employee_employment;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS eem_update ON employee_employment;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. employee_addresses
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS employee_addresses_insert ON employee_addresses;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS employee_addresses_update ON employee_addresses;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. emergency_contacts
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS emergency_contacts_insert ON emergency_contacts;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS emergency_contacts_update ON emergency_contacts;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 6. identity_records
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS identity_records_insert ON identity_records;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS identity_records_update ON identity_records;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ══════════════════════════════════════════════════════════════════════════════
-- 7. passports
-- ══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS passports_insert ON passports;
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );

DROP POLICY IF EXISTS passports_update ON passports;
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
          AND  e.locked     = false
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
          AND  e.locked     = false
          AND  e.deleted_at IS NULL
      )
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE 'Migration 434: satellite lock guard (locked = false) applied to 14 INSERT/UPDATE policies across 7 tables. employee_dependents and employee_education deferred pending table availability.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 20260603434_satellite_lock_guard.sql
-- =============================================================================
