-- =============================================================================
-- Migration 550 — Delete legacy employee.* and profile.* permissions
--
-- These codes were superseded by granular module codes:
--   personal_info.*, employment.*, contact_info.*, address.*,
--   education.*, emergency_contacts.*
--
-- Confirmed: zero can() / canFor() / requiredPermission references to
-- employee.* or profile.* exist anywhere in the frontend source.
-- All rows have no permission_set_items (shown as "No roles assigned"
-- in the Permission Catalog) so the delete has no cascade effect.
-- =============================================================================

DELETE FROM permissions
WHERE  code LIKE 'employee.%'
   OR  code LIKE 'profile.%';

DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM permissions
    WHERE code LIKE 'employee.%' OR code LIKE 'profile.%'
  ), 'legacy employee.* / profile.* permissions still exist after deletion';

  RAISE NOTICE 'Mig 550: all legacy employee.* and profile.* permissions removed.';
END;
$$;
