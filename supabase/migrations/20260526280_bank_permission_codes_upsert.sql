-- =============================================================================
-- Migration 280 — Ensure bank_accounts.view / bank_accounts.edit exist
-- =============================================================================
--
-- Migration 274 seeded permissions as "employee.view_bank_accounts" etc.
-- Migration 279 tried to rename them but the UPDATE may have found nothing
-- if the old codes were already gone or never inserted correctly.
--
-- This migration simply upserts the two permissions with the correct codes
-- that the PermissionMatrix component expects (moduleCode.action format),
-- then cleans up any legacy codes.
-- =============================================================================

-- 1. Ensure correct codes exist
INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('bank_accounts.view',
   'View Bank Accounts',
   'View bank account details for employees in your target group.',
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

-- 2. Migrate any grants on legacy codes to the new ones (safe if none exist)
DO $$
DECLARE
  v_old_view  uuid;
  v_old_edit  uuid;
  v_new_view  uuid;
  v_new_edit  uuid;
BEGIN
  SELECT id INTO v_old_view FROM permissions WHERE code = 'employee.view_bank_accounts';
  SELECT id INTO v_old_edit FROM permissions WHERE code = 'employee.edit_bank_accounts';
  SELECT id INTO v_new_view FROM permissions WHERE code = 'bank_accounts.view';
  SELECT id INTO v_new_edit FROM permissions WHERE code = 'bank_accounts.edit';

  IF v_old_view IS NOT NULL AND v_new_view IS NOT NULL THEN
    UPDATE role_permissions SET permission_id = v_new_view
    WHERE permission_id = v_old_view;
  END IF;

  IF v_old_edit IS NOT NULL AND v_new_edit IS NOT NULL THEN
    UPDATE role_permissions SET permission_id = v_new_edit
    WHERE permission_id = v_old_edit;
  END IF;
END $$;

-- 3. Remove legacy codes
DELETE FROM permissions
WHERE code IN ('employee.view_bank_accounts', 'employee.edit_bank_accounts');

-- Verify
SELECT code, name, sort_order
FROM permissions
WHERE code LIKE 'bank_accounts.%'
ORDER BY sort_order;
