-- =============================================================================
-- Migration 110: Seed ESS permission set — matrix-controlled self-access
--
-- After migration 109 removed all hardcoded `get_my_employee_id()` bypasses,
-- ESS employees access their own data purely through user_can() Path C:
--
--   Path C: p_owner = caller's employee_id
--           → checks permission EXISTS in their role (is_active + expires_at)
--           → returns true/false
--           → no target_group membership check (own record IS the target)
--
-- This migration ensures the ESS permission set contains every permission
-- an employee needs to view and edit their own profile data. Without these
-- rows, Path C returns false and ESS employees are locked out.
--
-- Permissions seeded for ESS (all self-service, no target group needed):
--
--   employee_details.view   — see own employees row (required for any profile load)
--   personal_info.view/edit — Personal tab
--   contact_info.view/edit  — Contact tab
--   employment.view         — Employment tab (read-only for ESS)
--   address.view/edit       — Address tab
--   passport.view/edit      — Passport tab
--   identity_documents.view/edit — Identification tab
--   emergency_contacts.view/edit — Emergency Contact tab
--   expense_reports.view/create/edit — My Expenses
--
-- NOTE: target_group_id is NULL for ESS rows in permission_set_items
-- because target groups apply to EV/MSS scoped access. ESS self-access
-- is governed entirely by Path C — no group membership check needed.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: insert permission_set_items by permission code
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_set_items (permission_set_id, permission_id)
SELECT ps.id, p.id
FROM   permission_sets ps
CROSS  JOIN permissions p
WHERE  ps.name = 'ESS'
AND    p.code IN (
  -- Core employee row visibility (required for MyProfile page load)
  'employee_details.view',

  -- Personal tab
  'personal_info.view',
  'personal_info.edit',

  -- Contact tab
  'contact_info.view',
  'contact_info.edit',

  -- Employment tab (read-only — ESS cannot change their own job/dept)
  'employment.view',

  -- Address tab
  'address.view',
  'address.edit',

  -- Passport tab
  'passport.view',
  'passport.edit',

  -- Identification tab
  'identity_documents.view',
  'identity_documents.edit',

  -- Emergency Contact tab
  'emergency_contacts.view',
  'emergency_contacts.edit',

  -- My Expenses
  'expense_reports.view',
  'expense_reports.create',
  'expense_reports.edit'
)
ON CONFLICT DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Expected: one row per code above, all under ESS
SELECT ps.name AS permission_set, p.code AS permission
FROM   permission_sets        ps
JOIN   permission_set_items   psi ON psi.permission_set_id = ps.id
JOIN   permissions            p   ON p.id = psi.permission_id
WHERE  ps.name = 'ESS'
AND    p.code IN (
  'employee_details.view',
  'personal_info.view',    'personal_info.edit',
  'contact_info.view',     'contact_info.edit',
  'employment.view',
  'address.view',          'address.edit',
  'passport.view',         'passport.edit',
  'identity_documents.view','identity_documents.edit',
  'emergency_contacts.view','emergency_contacts.edit',
  'expense_reports.view',  'expense_reports.create',  'expense_reports.edit'
)
ORDER BY p.code;

-- =============================================================================
-- END OF MIGRATION 110
--
-- Run order: 109 → 110
-- After both applied: regen TypeScript types.
-- Then update MyProfile.tsx frontend can() checks (Point 5).
-- =============================================================================
