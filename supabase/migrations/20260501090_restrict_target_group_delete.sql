-- =============================================================================
-- Migration : 20260501090_restrict_target_group_delete.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description:
--   Changes role_permissions.target_group_id FK from ON DELETE SET NULL
--   to ON DELETE RESTRICT.
--
--   Why: The previous SET NULL behaviour silently widened permissions —
--   deleting a target group would flip all scoped role_permissions rows
--   to NULL (= no scoping = everyone), a dangerous side-effect.
--
--   With RESTRICT, Postgres blocks the DELETE on target_groups if any
--   role_permissions row still references it, giving a clear error.
--   The UI already disables the Delete button when usageCount > 0;
--   this constraint is the DB-level safety net.
-- =============================================================================

ALTER TABLE role_permissions
  DROP CONSTRAINT IF EXISTS role_permissions_target_group_id_fkey;

ALTER TABLE role_permissions
  ADD CONSTRAINT role_permissions_target_group_id_fkey
  FOREIGN KEY (target_group_id)
  REFERENCES target_groups (id)
  ON DELETE RESTRICT;

-- =============================================================================
-- END OF MIGRATION 20260501090_restrict_target_group_delete.sql
-- =============================================================================
