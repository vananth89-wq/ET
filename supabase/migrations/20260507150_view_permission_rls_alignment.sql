-- =============================================================================
-- Migration 150: Align SELECT RLS with view-permission split
--
-- CONTEXT
-- ───────
-- Migrations 124 (target_groups) and 125 (role_assignments) added `.edit`
-- permissions and re-pointed all write RLS.  The frontend Permission Matrix
-- now exposes both `.view` and `.edit` toggles for both modules.
--
-- Two gaps remained:
--
-- 1. user_roles SELECT — migration 125 gated admin-level reads on
--    user_can('sec_role_assignments','edit',NULL).  A user who holds only
--    sec_role_assignments.view can access the Role Assignments tab but sees
--    no member lists, member counts, or History (audit_log reads are
--    filtered per-row by user_id = auth.uid() alone).
--
-- 2. audit_log SELECT — the current policy (migration 140) allows:
--      user_id = auth.uid() OR user_can('sys_audit_log','view',NULL)
--    The Role Assignments page loads history by entity_type/entity_id, not
--    by user_id.  A view-only sec_role_assignments user cannot see role
--    history unless they also hold sys_audit_log.view.
--
-- FIXES
-- ─────
-- 1. user_roles_select  → use sec_role_assignments.view (superset of edit)
-- 2. audit_log_select   → add OR user_can('sec_role_assignments','view',NULL)
--
-- target_groups / target_group_members SELECT policies are already
-- USING (true), so they work for view-only users without any change.
--
-- IMPORTANT: profile_id = auth.uid() self-access is preserved in
-- user_roles_select so AuthContext (which still reads this table) continues
-- to work for every authenticated user regardless of their permissions.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Fix user_roles SELECT — was gated on edit, now gated on view
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Before: profile_id = auth.uid() OR user_can('sec_role_assignments','edit',NULL)
-- After:  profile_id = auth.uid() OR user_can('sec_role_assignments','view',NULL)
--
-- Why .view rather than .edit?
--   • .view is required to even reach the Role Assignments page (App.tsx route
--     guard uses sec_role_assignments.view).
--   • Every user who has .edit also has .view (the UI cascade keeps them in sync).
--   • Switching to .view means view-only admins can load member lists and counts.

DROP POLICY IF EXISTS user_roles_select ON user_roles;

CREATE POLICY user_roles_select ON user_roles
  FOR SELECT
  USING (
    profile_id = auth.uid()
    OR user_can('sec_role_assignments', 'view', NULL)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Fix audit_log SELECT — add sec_role_assignments.view as an allowed reader
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The History tab in Role Assignments queries:
--   SELECT … FROM audit_log
--   WHERE entity_type = 'user_roles' AND entity_id = <roleId>
--   AND action IN ('role.member_added','role.member_removed')
--
-- That query returns zero rows under the old policy unless the user has
-- sys_audit_log.view.  We add sec_role_assignments.view as an additional
-- allowed reader so role admins can see role-assignment history without
-- needing the broader sys_audit_log.view grant.

DROP POLICY IF EXISTS audit_log_select ON audit_log;

CREATE POLICY audit_log_select ON audit_log FOR SELECT
  USING (
    user_id = auth.uid()
    OR user_can('sys_audit_log',       'view', NULL)
    OR user_can('sec_role_assignments','view', NULL)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm user_roles SELECT now references .view
SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'user_roles'
  AND  cmd = 'SELECT';

-- Confirm audit_log SELECT has the new OR clause
SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'audit_log'
  AND  cmd = 'SELECT';

-- =============================================================================
-- END OF MIGRATION 150
--
-- BEHAVIOUR SUMMARY
-- ─────────────────
-- sec_role_assignments.view  → read roles, user_roles (member lists / counts),
--                              audit_log (role.member_added/removed history)
-- sec_role_assignments.edit  → all of the above PLUS write to roles, user_roles
--
-- sec_target_groups.view     → read target_groups, target_group_members
--                              (no change — both tables were already USING true)
-- sec_target_groups.edit     → write to target_groups, target_group_members
-- =============================================================================
