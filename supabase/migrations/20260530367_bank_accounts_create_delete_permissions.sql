-- =============================================================================
-- Migration 367 — Bank Accounts: add create + delete permissions
--
-- Splits the existing single 'edit' permission into three granular actions:
--   create — add a new bank account card
--   edit   — change fields on an existing account
--   delete — remove (trash) an existing account
--
-- Existing bank_accounts.edit permission is preserved unchanged so existing
-- permission set grants are not disrupted. Admins add create/delete on top.
-- =============================================================================

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'bank_accounts';

  -- bank_accounts module may be registered under a different code — try by
  -- matching an existing permission's module_id as a fallback
  IF v_module_id IS NULL THEN
    SELECT module_id INTO v_module_id
    FROM permissions WHERE code = 'bank_accounts.edit' LIMIT 1;
  END IF;

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'bank_accounts module not found — skipping';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    ('bank_accounts.create',
     v_module_id, 'create',
     'Bank Accounts — Add',
     'Add a new bank account for an employee.'),
    ('bank_accounts.delete',
     v_module_id, 'delete',
     'Bank Accounts — Remove',
     'Remove (trash) an existing bank account.')
  ON CONFLICT (code) DO NOTHING;
END;
$$;

SELECT code, action FROM permissions
WHERE code IN ('bank_accounts.create', 'bank_accounts.delete')
ORDER BY code;
