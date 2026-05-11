-- =============================================================================
-- Migration 178: broaden profiles_select RLS policy
--
-- PROBLEM
-- ───────
-- profiles_select (mig 008 / phase1_has_permission_rls) only allows:
--   id = auth.uid()     — own profile
--   has_role('admin')   — system admins
--
-- This blocked any non-admin user from reading another user's profile row,
-- which broke the Approver Inbox "Reassign" typeahead. The search correctly
-- finds employees via the employees table, but the second step — fetching
-- profile IDs via profiles.employee_id — returned empty because RLS stripped
-- every row that wasn't the current user's own profile.
--
-- FIX
-- ───
-- Add a third condition mirroring employees_select:
--   employee_id IS NOT NULL
--   AND user_can('employee_details', 'view', employee_id)
--
-- If a user can see an employee (via permission set + target group), they can
-- also read that employee's profiles row. The profiles table only contains
-- id (auth UUID), employee_id, is_active, created_at, updated_at — no
-- sensitive data. This is consistent with the employees_select pattern and
-- makes profiles visibility follow the same permission model automatically.
--
-- IMPACT
-- ──────
-- • Reassign typeahead in Approver Inbox now works for non-admin approvers.
-- • Any future feature looking up profile IDs by employee automatically works.
-- • No new RPCs or SECURITY DEFINER functions needed.
-- • Admins and own-profile reads unchanged.
--
-- =============================================================================

DROP POLICY IF EXISTS profiles_select ON profiles;

CREATE POLICY profiles_select ON profiles FOR SELECT
  USING (
    -- Own profile — always readable
    id = auth.uid()

    -- Admins can read all profiles
    OR has_role('admin')

    -- Any employee whose details the current user can view (same gate as
    -- employees_select) — allows profile ID lookups for reassign, org chart, etc.
    OR (
      employee_id IS NOT NULL
      AND user_can('employee_details', 'view', employee_id)
    )
  );

COMMENT ON POLICY profiles_select ON profiles IS
  'Own profile always readable. Admins read all. Non-admin users can read '
  'profiles for employees they have employee_details.view permission on '
  '(mirrors employees_select). Added employee_details path in mig 178.';

-- =============================================================================
-- END OF MIGRATION 178
-- =============================================================================
