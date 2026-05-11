-- =============================================================================
-- Migration 142: Upgrade app_config, module_registry & module_codes RLS
--                to is_super_admin() — no Permission Matrix toggle
--
-- RATIONALE
-- ─────────
-- These three tables define system-level configuration that controls how the
-- application itself behaves. They are not business-data tables and should
-- never be toggled via the Permission Matrix UI:
--
--   app_config      — runtime feature flags and system settings
--   module_codes    — the canonical list of module codes (FK target)
--   module_registry — per-module routing rules for user_can() and can_view/write
--
-- Gating writes on is_super_admin() (UUID allowlist, migration 112) rather
-- than has_role('admin') means:
--   • Access cannot be accidentally granted via the Role Assignments UI
--   • Changing system config requires explicit super admin enrolment
--   • No circular dependency — is_super_admin() reads super_admins directly,
--     not through user_can() or any permission chain
--
-- READ POLICIES
-- ─────────────
--   app_config      — super admin only (was: has_role + has_permission)
--   module_codes    — open to all authenticated (unchanged — needed for FK resolvers)
--   module_registry — open to all authenticated (unchanged — needed for can_view_module_record)
-- =============================================================================


-- ── 1. app_config ─────────────────────────────────────────────────────────────
-- Currently only a SELECT policy exists. We add explicit write policies
-- so super admins can manage config rows, and restrict SELECT to super admins.

DROP POLICY IF EXISTS app_config_admin_select ON app_config;

CREATE POLICY app_config_select ON app_config FOR SELECT
  USING (is_super_admin());

CREATE POLICY app_config_insert ON app_config FOR INSERT
  WITH CHECK (is_super_admin());

CREATE POLICY app_config_update ON app_config FOR UPDATE
  USING      (is_super_admin())
  WITH CHECK (is_super_admin());

CREATE POLICY app_config_delete ON app_config FOR DELETE
  USING (is_super_admin());


-- ── 2. module_codes ───────────────────────────────────────────────────────────
-- SELECT stays open (needed for FK resolution across the app).
-- FOR ALL admin catch-all → explicit write policies gated on is_super_admin().

DROP POLICY IF EXISTS module_codes_admin ON module_codes;

CREATE POLICY module_codes_insert ON module_codes FOR INSERT
  WITH CHECK (is_super_admin());

CREATE POLICY module_codes_update ON module_codes FOR UPDATE
  USING      (is_super_admin())
  WITH CHECK (is_super_admin());

CREATE POLICY module_codes_delete ON module_codes FOR DELETE
  USING (is_super_admin());


-- ── 3. module_registry ────────────────────────────────────────────────────────
-- SELECT stays open (needed for can_view_module_record() and can_write_module_record()).
-- FOR ALL admin catch-all → explicit write policies gated on is_super_admin().

DROP POLICY IF EXISTS module_registry_admin ON module_registry;

CREATE POLICY module_registry_insert ON module_registry FOR INSERT
  WITH CHECK (is_super_admin());

CREATE POLICY module_registry_update ON module_registry FOR UPDATE
  USING      (is_super_admin())
  WITH CHECK (is_super_admin());

CREATE POLICY module_registry_delete ON module_registry FOR DELETE
  USING (is_super_admin());


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('app_config', 'module_codes', 'module_registry')
ORDER BY tablename, cmd, policyname;
