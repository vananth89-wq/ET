-- =============================================================================
-- Migration 151: Remove all SQL-seeded permission_set_items
--
-- CONTEXT
-- ───────
-- Migrations 110 and 147 hardcoded permission_set_items rows for the ESS
-- permission set.  This conflicts with the principle that the Permission
-- Matrix UI is the single source of truth for what each permission set
-- contains.  Seeded rows cannot be meaningfully toggled off by an admin
-- because a re-run of the migration would restore them.
--
-- WHAT THIS DOES
-- ──────────────
-- Deletes all permission_set_items rows that were seeded by migrations:
--
--   Migration 110 seeded (ESS):
--     employee_details.view
--     personal_info.view / personal_info.edit
--     contact_info.view  / contact_info.edit
--     employment.view
--     address.view       / address.edit
--     passport.view      / passport.edit
--     identity_documents.view / identity_documents.edit
--     emergency_contacts.view / emergency_contacts.edit
--     expense_reports.view / expense_reports.create / expense_reports.edit
--
--   Migration 147 seeded (ESS):
--     projects.lookup
--     currencies.lookup
--     picklists.lookup
--     departments.lookup
--
-- AFTER THIS MIGRATION
-- ────────────────────
-- The ESS permission set will have no items.  An admin must configure
-- it via the Permission Matrix UI before employees can access any data.
-- No future migration should INSERT into permission_set_items.
-- =============================================================================


DELETE FROM permission_set_items
WHERE permission_set_id = (
  SELECT id FROM permission_sets WHERE name = 'ESS'
)
AND permission_id IN (
  SELECT id FROM permissions
  WHERE code IN (
    -- Migration 110
    'employee_details.view',
    'personal_info.view',    'personal_info.edit',
    'contact_info.view',     'contact_info.edit',
    'employment.view',
    'address.view',          'address.edit',
    'passport.view',         'passport.edit',
    'identity_documents.view','identity_documents.edit',
    'emergency_contacts.view','emergency_contacts.edit',
    'expense_reports.view',  'expense_reports.create',  'expense_reports.edit',
    -- Migration 147
    'projects.lookup',
    'currencies.lookup',
    'picklists.lookup',
    'departments.lookup'
  )
);


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Expected: 0 rows remaining for ESS
SELECT COUNT(*) AS remaining_ess_items
FROM   permission_set_items psi
JOIN   permission_sets ps ON ps.id = psi.permission_set_id
WHERE  ps.name = 'ESS';

-- =============================================================================
-- END OF MIGRATION 151
--
-- NEXT STEP
-- ─────────
-- Open the Permission Matrix UI and configure the ESS permission set
-- with the permissions appropriate for your organisation.
-- =============================================================================
