-- =============================================================================
-- Migration 296 — Align bank_accounts and dependents RLS with personal info pattern
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- Personal info tables (employee_personal, employee_contact, employee_addresses,
-- passports, emergency_contacts, identity_records) use a dual-path RLS design
-- established in Migration 220:
--
--   PATH A — Active employees (target-group scoped):
--     user_can('<module>', '<action>', employee_id)
--     → Path D: checks target_group_members cache
--     → Also Path C (self shortcircuit) when employee_id = caller's employee_id
--
--   PATH B — Hire pipeline (new hire not yet in target group cache):
--     user_can('<module>', '<action>', NULL)       ← permission exists in any role
--     AND user_can('hire_employee', 'view/edit', NULL)  ← HR guard (not ESS)
--     AND employee.status IN ('Draft', 'Incomplete', 'Pending')
--
-- The HR guard is essential: without it, any ESS user with personal_info.view
-- (self-scope) would satisfy the OR branch and could read all draft employees.
-- user_can('hire_employee', 'view/edit', NULL) is only granted to HR roles.
--
-- CURRENT GAP
-- ───────────
-- employee_bank_accounts and employee_dependents use an older pattern:
--   user_can('bank_accounts', 'view', employee_id)
--   OR (employee_id = get_my_employee_id() AND has_permission('bank_accounts.view'))
--
-- The ESS self-path is redundant — user_can(..., employee_id) already handles
-- self access via Path C. More importantly, neither table has the hire-pipeline
-- OR branch, so direct table queries for Pending employees fail at the RLS layer
-- (though RPCs bypass this via SECURITY DEFINER).
--
-- FIX
-- ───
-- Recreate all RLS policies on:
--   employee_bank_accounts        (module: bank_accounts)
--   employee_bank_attachments     (joined via bank_account_id)
--   employee_dependents           (module: dependents)
--   employee_dependent_attachments (joined via dependent_code + employee_id)
--
-- Each policy follows the Migration 220 dual-path design exactly.
-- =============================================================================


-- =============================================================================
-- 1. employee_bank_accounts
-- =============================================================================

DROP POLICY IF EXISTS "bank_accounts_select"  ON employee_bank_accounts;
DROP POLICY IF EXISTS "bank_accounts_insert"  ON employee_bank_accounts;
DROP POLICY IF EXISTS "bank_accounts_update"  ON employee_bank_accounts;
DROP POLICY IF EXISTS "bank_accounts_delete"  ON employee_bank_accounts;

CREATE POLICY "bank_accounts_select" ON employee_bank_accounts
  FOR SELECT USING (
    -- Path A: active employee, target-group scoped (also handles ESS self via Path C)
    user_can('bank_accounts', 'view', employee_id)
    -- Path B: hire pipeline — new hire not yet in target_group_members cache
    OR (
      user_can('bank_accounts',   'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_accounts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_accounts_insert" ON employee_bank_accounts
  FOR INSERT WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_accounts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_accounts_update" ON employee_bank_accounts
  FOR UPDATE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_accounts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_accounts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_accounts_delete" ON employee_bank_accounts
  FOR DELETE USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_accounts.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- =============================================================================
-- 2. employee_bank_attachments
-- =============================================================================

DROP POLICY IF EXISTS "bank_attachments_select" ON employee_bank_attachments;
DROP POLICY IF EXISTS "bank_attachments_insert" ON employee_bank_attachments;
DROP POLICY IF EXISTS "bank_attachments_update" ON employee_bank_attachments;
DROP POLICY IF EXISTS "bank_attachments_delete" ON employee_bank_attachments;

CREATE POLICY "bank_attachments_select" ON employee_bank_attachments
  FOR SELECT USING (
    user_can('bank_accounts', 'view', employee_id)
    OR (
      user_can('bank_accounts',   'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_attachments_insert" ON employee_bank_attachments
  FOR INSERT WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_attachments_update" ON employee_bank_attachments
  FOR UPDATE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY "bank_attachments_delete" ON employee_bank_attachments
  FOR DELETE USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      user_can('bank_accounts',   'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_bank_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- =============================================================================
-- 3. employee_dependents
-- =============================================================================

DROP POLICY IF EXISTS ed_select ON employee_dependents;
DROP POLICY IF EXISTS ed_insert ON employee_dependents;
DROP POLICY IF EXISTS ed_update ON employee_dependents;
DROP POLICY IF EXISTS ed_delete ON employee_dependents;

CREATE POLICY ed_select ON employee_dependents FOR SELECT
  USING (
    -- view OR edit both grant read access (same as original policy)
    user_can('dependents', 'view', employee_id)
    OR user_can('dependents', 'edit', employee_id)
    OR (
      (
        user_can('dependents', 'view', NULL)
        OR user_can('dependents', 'edit', NULL)
      )
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependents.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ed_insert ON employee_dependents FOR INSERT
  WITH CHECK (
    user_can('dependents', 'create', employee_id)
    OR (
      user_can('dependents',    'create', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependents.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY ed_update ON employee_dependents FOR UPDATE
  USING (
    user_can('dependents', 'edit', employee_id)
    OR (
      user_can('dependents',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependents.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('dependents', 'edit', employee_id)
    OR (
      user_can('dependents',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependents.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

-- DELETE: HR/admin only — employees must use remove_dependent() RPC (soft-delete)
CREATE POLICY ed_delete ON employee_dependents FOR DELETE
  USING (
    user_can('dependents', 'delete', employee_id)
    OR (
      user_can('dependents',    'delete', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependents.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- =============================================================================
-- 4. employee_dependent_attachments
-- =============================================================================

DROP POLICY IF EXISTS eda_select ON employee_dependent_attachments;
DROP POLICY IF EXISTS eda_insert ON employee_dependent_attachments;
DROP POLICY IF EXISTS eda_update ON employee_dependent_attachments;
DROP POLICY IF EXISTS eda_delete ON employee_dependent_attachments;

CREATE POLICY eda_select ON employee_dependent_attachments FOR SELECT
  USING (
    user_can('dependents', 'view', employee_id)
    OR user_can('dependents', 'edit', employee_id)
    OR (
      (
        user_can('dependents', 'view', NULL)
        OR user_can('dependents', 'edit', NULL)
      )
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependent_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eda_insert ON employee_dependent_attachments FOR INSERT
  WITH CHECK (
    -- Allow both create (new dependent) and edit (amend) for attachment uploads
    user_can('dependents', 'create', employee_id)
    OR user_can('dependents', 'edit', employee_id)
    OR (
      (
        user_can('dependents', 'create', NULL)
        OR user_can('dependents', 'edit', NULL)
      )
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependent_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eda_update ON employee_dependent_attachments FOR UPDATE
  USING (
    user_can('dependents', 'edit', employee_id)
    OR (
      user_can('dependents',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependent_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  )
  WITH CHECK (
    user_can('dependents', 'edit', employee_id)
    OR (
      user_can('dependents',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependent_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );

CREATE POLICY eda_delete ON employee_dependent_attachments FOR DELETE
  USING (
    user_can('dependents', 'delete', employee_id)
    OR (
      user_can('dependents',    'delete', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = employee_dependent_attachments.employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  );


-- =============================================================================
-- Verification
-- =============================================================================

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM   pg_policies
  WHERE  tablename IN (
    'employee_bank_accounts', 'employee_bank_attachments',
    'employee_dependents',    'employee_dependent_attachments'
  );

  ASSERT v_count >= 16,
    'Expected at least 16 RLS policies across 4 tables after migration 296 (got ' || v_count || ')';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 296
-- =============================================================================
--
-- ACCESS MATRIX (mirrors Migration 220):
--
--   Actor                          | bank_accounts | dependents
--   ───────────────────────────────┼───────────────┼───────────────
--   HR admin (active employee)     | Path A ✓      | Path A ✓
--   HR admin (new hire / Pending)  | Path B ✓      | Path B ✓
--   ESS employee (self, active)    | Path A ✓      | Path A ✓
--   ESS employee (no hire_employee)| Blocked ✓     | Blocked ✓
--   Approver (via RPC)             | SECURITY DEF  | SECURITY DEF
--   Approver (direct table)        | Path B ✓      | Path B ✓
-- =============================================================================
