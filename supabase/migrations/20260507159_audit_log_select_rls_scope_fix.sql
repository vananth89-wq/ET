-- =============================================================================
-- Migration 159: Scope audit_log SELECT for sec_role_assignments.view
--
-- BUG
-- ───
-- Migration 150 added sec_role_assignments.view as an allowed reader on
-- audit_log so role admins could see role-assignment history. However the
-- USING clause was unscoped:
--
--   OR user_can('sec_role_assignments','view',NULL)
--
-- RLS USING is a row-level gate — not a query filter. A user with
-- sec_role_assignments.view therefore passes the check for EVERY row in
-- audit_log, exposing expense report events, login events, HR actions, etc.
-- The WHERE clause the application adds (entity_type = 'user_roles') only
-- limits what the UI displays; it does not restrict a direct DB query.
--
-- FIX
-- ───
-- Wrap the sec_role_assignments.view clause so it only grants access to rows
-- whose entity_type belongs to the role/permission domain:
--
--   user_roles                — role membership changes
--   permission_set_assignments — which permission sets a role holds
--   permission_set_items      — individual permission entries within a set
--
-- This mirrors exactly the domain access check used in get_record_history()
-- (migration 158) for the same permission combination.
--
-- FINAL POLICY
-- ────────────
--   user_id = auth.uid()                          — own activity
--   OR user_can('sys_audit_log','view',NULL)       — full central admin access
--   OR (
--     user_can('sec_role_assignments','view',NULL)
--     AND entity_type IN (
--       'user_roles',
--       'permission_set_assignments',
--       'permission_set_items'
--     )
--   )                                              — role/permission history only
-- =============================================================================


DROP POLICY IF EXISTS audit_log_select ON audit_log;

CREATE POLICY audit_log_select ON audit_log FOR SELECT
  USING (
    user_id = auth.uid()
    OR user_can('sys_audit_log', 'view', NULL)
    OR (
      user_can('sec_role_assignments', 'view', NULL)
      AND entity_type IN (
        'user_roles',
        'permission_set_assignments',
        'permission_set_items'
      )
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'audit_log'
ORDER  BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 159
-- =============================================================================
