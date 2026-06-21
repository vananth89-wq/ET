-- =============================================================================
-- Migration 294 — Add history permissions for bank_accounts and dependents
-- =============================================================================
--
-- PROBLEM
-- ───────
-- PermissionMatrix now shows a History column for bank_accounts and dependents
-- rows but the underlying permissions.history rows don't exist in the DB,
-- so permId() returns null and the checkboxes can never be saved.
--
-- FIX
-- ───
-- Seed bank_accounts.history and dependents.history with action = 'history'.
-- =============================================================================

INSERT INTO permissions (code, name, description, module_id, action, sort_order)
SELECT p.code, p.name, p.description, m.id, p.action, p.sort_order
FROM (VALUES
  ('bank_accounts.history',
   'Bank Account History',
   'View the full change history and audit trail for employee bank accounts.',
   'history', 136),
  ('dependents.history',
   'Dependent History',
   'View the full change history and audit trail for employee dependent records.',
   'history', 144)
) AS p(code, name, description, action, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET action      = EXCLUDED.action,
      name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT COUNT(*) FROM permissions
    WHERE  code IN ('bank_accounts.history', 'dependents.history')
      AND  action = 'history'
  ) = 2,
  'Expected 2 history permissions (bank_accounts + dependents) after migration 294';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 294
-- =============================================================================
