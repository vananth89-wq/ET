-- =============================================================================
-- Migration 293 — Set action column on dependents permissions
-- =============================================================================
--
-- PROBLEM
-- ───────
-- Migration 289 inserted dependents.view / .create / .edit / .delete without
-- setting the `action` column (left NULL).
--
-- PermissionMatrix loads permissions with:
--   .not('action', 'is', null)
-- So NULL-action rows are invisible to the frontend — permId() returns null
-- and checkbox clicks are silently dropped (same root cause as bank_accounts
-- fixed in migration 281).
--
-- FIX
-- ───
-- Set action = 'view' / 'create' / 'edit' / 'delete' on the four rows.
-- Also upsert in full with action set, so this is idempotent if run again.
-- =============================================================================

-- Update existing rows that have NULL action
UPDATE permissions SET action = 'view'   WHERE code = 'dependents.view'   AND (action IS NULL OR action <> 'view');
UPDATE permissions SET action = 'create' WHERE code = 'dependents.create' AND (action IS NULL OR action <> 'create');
UPDATE permissions SET action = 'edit'   WHERE code = 'dependents.edit'   AND (action IS NULL OR action <> 'edit');
UPDATE permissions SET action = 'delete' WHERE code = 'dependents.delete' AND (action IS NULL OR action <> 'delete');

-- Belt-and-suspenders: upsert with action in case rows are missing
INSERT INTO permissions (code, name, description, module_id, action, sort_order)
SELECT p.code, p.name, p.description, m.id, p.action, p.sort_order
FROM (VALUES
  ('dependents.view',
   'View Dependents',
   'View dependent records for employees in your target group.',
   'view',   140),
  ('dependents.create',
   'Add Dependents',
   'Add new dependent records for employees in your target group.',
   'create', 141),
  ('dependents.edit',
   'Edit Dependents',
   'Edit and amend dependent records for employees in your target group.',
   'edit',   142),
  ('dependents.delete',
   'Remove Dependents',
   'Remove (terminate) dependent records for employees in your target group.',
   'delete', 143)
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
    WHERE  code IN ('dependents.view','dependents.create','dependents.edit','dependents.delete')
      AND  action IS NOT NULL
  ) = 4,
  'Expected 4 dependents permissions with non-null action after migration 293';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 293
-- =============================================================================
