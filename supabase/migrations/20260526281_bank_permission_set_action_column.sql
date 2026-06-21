-- =============================================================================
-- Migration 281 — Set action column on bank_accounts permissions
-- =============================================================================
--
-- PROBLEM
-- ───────
-- Migrations 274 and 280 inserted bank_accounts.view / bank_accounts.edit
-- without setting the `action` column (left NULL).
--
-- PermissionMatrix loads permissions with:
--   .not('action', 'is', null)
-- So NULL-action rows are invisible to the frontend — permId() returns null
-- and checkbox clicks are silently dropped.
--
-- FIX
-- ───
-- Set action = 'view' / 'edit' on the two rows (deriving from the code suffix).
-- Also upsert them in full (with action) so this is idempotent if run again.
-- =============================================================================

-- Update existing rows that have NULL action
UPDATE permissions
SET action = 'view'
WHERE code = 'bank_accounts.view' AND (action IS NULL OR action <> 'view');

UPDATE permissions
SET action = 'edit'
WHERE code = 'bank_accounts.edit' AND (action IS NULL OR action <> 'edit');

-- If the rows were never inserted (belt-and-suspenders) — insert them now with action set
INSERT INTO permissions (code, name, description, module_id, action, sort_order)
SELECT p.code, p.name, p.description, m.id, p.action, p.sort_order
FROM (VALUES
  ('bank_accounts.view', 'View Bank Accounts',
   'View bank account details for employees in your target group.',
   'view', 130),
  ('bank_accounts.edit', 'Edit Bank Accounts',
   'Add and amend bank account records for employees in your target group.',
   'edit', 135)
) AS p(code, name, description, action, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET action      = EXCLUDED.action,
      name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;

-- Verify
SELECT code, name, action, sort_order
FROM permissions
WHERE code LIKE 'bank_accounts.%'
ORDER BY sort_order;
