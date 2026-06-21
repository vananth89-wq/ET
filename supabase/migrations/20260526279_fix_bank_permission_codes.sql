-- =============================================================================
-- Migration 279 — Fix bank account permission codes
-- =============================================================================
--
-- PROBLEM
-- ───────
-- Migration 274 seeded permissions with codes "employee.view_bank_accounts"
-- and "employee.edit_bank_accounts".
--
-- The PermissionMatrix component builds lookup keys as:
--   `${moduleCode}.${action}`  →  "bank_accounts.view" / "bank_accounts.edit"
--
-- These don't match, so permId() returns null and checkbox clicks are dropped.
--
-- FIX
-- ───
-- Upsert the two permissions with the correct moduleCode.action format.
-- The INSERT...ON CONFLICT handles both cases:
--   • If old codes still exist  → they stay; new codes are inserted fresh
--   • If the old codes were already renamed → DO NOTHING prevents duplicates
--
-- Then delete the old codes (if they still exist) to avoid duplicates.
-- =============================================================================

-- 1. Ensure the correctly-named permissions exist
INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('bank_accounts.view',
   'View Bank Accounts',
   'View the Bank Accounts portlet for employees in your target group.',
   130),
  ('bank_accounts.edit',
   'Edit Bank Accounts',
   'Add and amend bank account records for employees in your target group.',
   135)
) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;

-- 2. Migrate any existing role_permission grants from the old codes to the new ones
UPDATE role_permissions rp
SET permission_id = new_p.id
FROM permissions old_p
JOIN permissions new_p ON new_p.code = REPLACE(old_p.code, 'employee.view_bank_accounts', 'bank_accounts.view')
WHERE rp.permission_id = old_p.id
  AND old_p.code = 'employee.view_bank_accounts';

UPDATE role_permissions rp
SET permission_id = new_p.id
FROM permissions old_p
JOIN permissions new_p ON new_p.code = 'bank_accounts.edit'
WHERE rp.permission_id = old_p.id
  AND old_p.code = 'employee.edit_bank_accounts';

-- 3. Remove the old codes (now that grants have been migrated)
DELETE FROM permissions WHERE code IN ('employee.view_bank_accounts', 'employee.edit_bank_accounts');

-- Verify
SELECT code, name, sort_order
FROM permissions
WHERE code LIKE 'bank_accounts.%'
ORDER BY sort_order;
