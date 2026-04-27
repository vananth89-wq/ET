-- =============================================================================
-- Drop Legacy Employee Permissions
--
-- Removes the old coarse-grained employee permission codes that have been
-- fully replaced by the new granular set in 20260425021.
--
-- Replaced by:
--   employee.view          → employee.view_directory   (all roles)
--   employee.view_all      → employee.edit             (admin / HR)
--   employee.edit_sensitive→ employee.view_own_*/edit_own_* per portlet
--   employee.view_own      → employee.view_own_* per portlet
--   employee.view_team     → (future: team-scoped portlet permissions)
--
-- role_permissions rows cascade automatically via FK ON DELETE CASCADE.
-- =============================================================================

DELETE FROM permissions
WHERE code IN (
  'employee.view',
  'employee.view_all',
  'employee.edit_sensitive',
  'employee.view_own',
  'employee.view_team'
);

-- ── Verification ──────────────────────────────────────────────────────────────

SELECT code, name
FROM   permissions
WHERE  module_id = (SELECT id FROM modules WHERE code = 'employee')
ORDER  BY sort_order, code;
