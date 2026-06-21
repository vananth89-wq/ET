-- =============================================================================
-- Migration 551 — Delete legacy department.* permissions
--
-- All 7 codes (department.view, department.create, department.edit,
-- department.delete, department.manage_heads, department.view_members,
-- department.view_orgchart) show "No roles assigned" — never assigned to
-- any permission set.
--
-- Confirmed: zero can() / canFor() / requiredPermission references to
-- department.* in the frontend. department.bulk_import / department.bulk_export
-- are separate codes and are NOT deleted here.
-- =============================================================================

DELETE FROM permissions
WHERE  code IN (
  'department.view',
  'department.create',
  'department.edit',
  'department.delete',
  'department.manage_heads',
  'department.view_members',
  'department.view_orgchart'
);

DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM permissions
    WHERE code IN (
      'department.view', 'department.create', 'department.edit',
      'department.delete', 'department.manage_heads',
      'department.view_members', 'department.view_orgchart'
    )
  ), 'legacy department.* permissions still exist after deletion';

  RAISE NOTICE 'Mig 551: legacy department.* permissions removed.';
END;
$$;
