-- =============================================================================
-- Migration 102: Fix get_my_permissions() — include permission_sets
--
-- PROBLEM
-- ───────
-- The Permission Matrix UI (migration 092) saves permissions to:
--   permission_sets → permission_set_items → permission_set_assignments
--
-- But get_my_permissions() only reads from:
--   user_roles → role_permissions → permissions
--
-- So toggling a permission in the matrix has NO effect on what can() returns
-- in the frontend — the nav item never appears, routes remain blocked.
--
-- FIX
-- ───
-- Extend get_my_permissions() to UNION both sources:
--   Path A (legacy): user_roles → role_permissions → permissions
--   Path B (matrix): user_roles → permission_set_assignments
--                    → permission_set_items → permissions
--
-- get_my_permissions() is called once on login and cached in PermissionContext.
-- Both paths produce permission.code strings — the union is transparent to all
-- callers.
--
-- user_can() is NOT changed — it reads role_permissions directly for RLS.
-- The RLS bridge (writing matrix grants to role_permissions) is a future task.
-- For now: can() / canAny() (UI gates) use the combined set; RLS uses only
-- role_permissions (unchanged).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Path A: legacy role_permissions direct grants
  SELECT COALESCE(array_agg(DISTINCT p.code), '{}')
  FROM   user_roles       ur
  JOIN   role_permissions  rp ON rp.role_id      = ur.role_id
  JOIN   permissions       p  ON p.id             = rp.permission_id
  WHERE  ur.profile_id        = auth.uid()
    AND  ur.is_active          = true
    AND  (ur.expires_at IS NULL OR ur.expires_at > now())

  UNION

  -- Path B: permission_set_assignments (Permission Matrix UI grants)
  SELECT DISTINCT p.code
  FROM   user_roles                ur
  JOIN   permission_set_assignments psa ON psa.role_id      = ur.role_id
  JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
  JOIN   permissions                p   ON p.id             = psi.permission_id
  WHERE  ur.profile_id        = auth.uid()
    AND  ur.is_active          = true
    AND  (ur.expires_at IS NULL OR ur.expires_at > now())
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes held by the current user. '
  'Path A: legacy role_permissions direct grants. '
  'Path B: permission_set_assignments from the Permission Matrix UI. '
  'Called once on login by PermissionContext; cached client-side in a Set. '
  'NOTE: user_can() (RLS) still reads role_permissions only — '
  'the matrix grants are UI-gate only until a sync migration bridges both.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT proname, prosrc LIKE '%permission_set_assignments%' AS includes_matrix_path
FROM   pg_proc
WHERE  proname = 'get_my_permissions';

-- =============================================================================
-- END OF MIGRATION 102
-- =============================================================================
