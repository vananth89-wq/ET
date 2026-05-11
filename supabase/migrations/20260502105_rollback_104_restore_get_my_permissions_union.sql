-- =============================================================================
-- Migration 105: Rollback migration 104 — restore get_my_permissions() UNION
--
-- Migration 104 simplified get_my_permissions() to read role_permissions only.
-- The Permission Matrix UI has been reverted to write permission_set_assignments
-- (not role_permissions), so the UNION with permission_set_assignments is
-- required for UI gates (can() / canAny()) to work.
--
-- This migration restores the exact function body from migration 102.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT code), '{}')
  FROM (
    -- Path A: legacy role_permissions direct grants
    SELECT p.code
    FROM   user_roles       ur
    JOIN   role_permissions  rp ON rp.role_id      = ur.role_id
    JOIN   permissions       p  ON p.id             = rp.permission_id
    WHERE  ur.profile_id        = auth.uid()
      AND  ur.is_active          = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())

    UNION

    -- Path B: permission_set_assignments (Permission Matrix UI grants)
    SELECT p.code
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id      = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id             = psi.permission_id
    WHERE  ur.profile_id        = auth.uid()
      AND  ur.is_active          = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
  ) combined
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes held by the current user. '
  'Path A: legacy role_permissions direct grants. '
  'Path B: permission_set_assignments from the Permission Matrix UI. '
  'Called once on login by PermissionContext; cached client-side in a Set. '
  'NOTE: user_can() (RLS) still reads role_permissions only — '
  'the matrix grants are UI-gate only until a sync migration bridges both.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION — should return TRUE
-- ─────────────────────────────────────────────────────────────────────────────

SELECT proname,
       prosrc LIKE '%permission_set_assignments%' AS includes_matrix_path
FROM   pg_proc
WHERE  proname = 'get_my_permissions';

-- Expected: includes_matrix_path = true

-- =============================================================================
-- END OF MIGRATION 105
-- =============================================================================
