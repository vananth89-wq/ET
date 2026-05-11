-- =============================================================================
-- Migration 127: Upgrade profiles RLS to is_super_admin() + self-access
--
-- BACKGROUND
-- ──────────
-- profiles currently uses has_role('admin') for admin-side access.
-- Agreed approach (option 1): no Permission Matrix module for profiles.
-- Access is governed by two rules only:
--   1. Self-access  — every user can read and update their own row.
--   2. Super admin  — is_super_admin() (UUID allowlist, migration 112)
--                     can read / update / delete any profile.
--
-- No INSERT policy exists or is needed — profiles are created exclusively
-- by Supabase's handle_new_user auth trigger, which is SECURITY DEFINER.
--
-- POLICIES CHANGED
-- ────────────────
--   profiles_select  — was: id = auth.uid() OR has_role('admin')
--   profiles_update  — was: id = auth.uid() OR has_role('admin')
--   profiles_delete  — was: has_role('admin')
-- =============================================================================


DROP POLICY IF EXISTS profiles_select ON profiles;
DROP POLICY IF EXISTS profiles_update ON profiles;
DROP POLICY IF EXISTS profiles_delete ON profiles;

CREATE POLICY profiles_select ON profiles
  FOR SELECT
  USING (id = auth.uid() OR is_super_admin());

CREATE POLICY profiles_update ON profiles
  FOR UPDATE
  USING      (id = auth.uid() OR is_super_admin())
  WITH CHECK (id = auth.uid() OR is_super_admin());

-- Only super admins can delete profiles; users cannot self-delete.
CREATE POLICY profiles_delete ON profiles
  FOR DELETE
  USING (is_super_admin());


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE tablename = 'profiles'
ORDER BY cmd, policyname;
