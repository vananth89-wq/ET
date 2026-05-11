-- =============================================================================
-- Migration 112: Super Admin infrastructure
--
-- DESIGN
-- ──────
-- Two-tier admin model:
--
--   super_admin  — UUID allowlist in super_admins table.
--                  Only service_role (Supabase dashboard) can INSERT / DELETE.
--                  Bypasses ALL permission checks in user_can().
--                  Break-glass account — never managed through the app.
--
--   admin role   — Normal role, fully matrix-controlled via permission sets.
--                  Goes through user_can() Paths B / C / D like every other role.
--                  Auditable and configurable in the Permission Matrix UI.
--
-- WHAT CHANGES
-- ────────────
--   super_admins table   — created here (UUID allowlist)
--   is_super_admin()     — SECURITY DEFINER, reads super_admins
--   user_can() Path A    — changed in migration 113 (this file does not touch it)
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
--   All RLS policies     — unchanged
--   user_can()           — unchanged until migration 113
--   has_role()           — unchanged
--   admin role           — still exists, still assigned, now purely matrix-controlled
--
-- SEEDING
-- ───────
-- The first super admin is inserted here via service_role (migration runner).
-- Additional entries must be managed via the Supabase dashboard SQL Editor
-- (service_role only — no app-level INSERT policy exists).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Create super_admins table
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS super_admins (
  profile_id  uuid        PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  granted_at  timestamptz NOT NULL DEFAULT now(),
  granted_by  text        -- free-text note, e.g. 'initial seed' or operator email
);

COMMENT ON TABLE super_admins IS
  'UUID allowlist of super-admin accounts. '
  'Only service_role can INSERT / DELETE — no app-level write policies exist. '
  'Managed exclusively via the Supabase dashboard SQL Editor.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS — read-only for authenticated users so is_super_admin() can query it
--          No INSERT / UPDATE / DELETE policies — service_role bypasses RLS
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE super_admins ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read (needed so is_super_admin() works inside user_can())
CREATE POLICY super_admins_select ON super_admins FOR SELECT
  TO authenticated
  USING (true);

-- No INSERT / UPDATE / DELETE policies.
-- service_role (Supabase dashboard / migrations) bypasses RLS and can write freely.


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. is_super_admin() function
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM super_admins WHERE profile_id = auth.uid()
  );
$$;

COMMENT ON FUNCTION is_super_admin() IS
  'Returns true if the current user is in the super_admins allowlist. '
  'SECURITY DEFINER STABLE — safe to call from RLS policies via user_can(). '
  'Replaces has_role(''admin'') as the Path A bypass in user_can() (migration 113).';

GRANT EXECUTE ON FUNCTION is_super_admin() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Seed the first super admin
--    profile_id = Vijey's account (vananth89@gmail.com / vijey@prowessinfotech.co.in)
--    This INSERT runs as service_role — no policy needed.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO super_admins (profile_id, granted_by)
VALUES (
  'a5407d95-a3e0-4993-8f58-4b3a23c9d392',
  'initial seed — migration 112'
)
ON CONFLICT (profile_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm super_admins table exists with the seed row
SELECT profile_id, granted_at, granted_by FROM super_admins;

-- Confirm is_super_admin() function exists
SELECT proname, prosrc LIKE '%super_admins%' AS reads_super_admins_table
FROM   pg_proc
WHERE  proname = 'is_super_admin';

-- =============================================================================
-- END OF MIGRATION 112
--
-- Run order: 109 → 110 → 112 → 113
-- After applying: run migration 113 to wire is_super_admin() into user_can().
-- =============================================================================
