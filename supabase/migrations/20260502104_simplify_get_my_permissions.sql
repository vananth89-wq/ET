-- =============================================================================
-- Migration 104: Simplify get_my_permissions() — single path
--
-- Migration 102 added a UNION with permission_set_assignments so UI gates
-- would work while the bridge was missing.  Now that migration 103 has
-- backfilled role_permissions from the matrix data, role_permissions is the
-- single source of truth.  The UNION is no longer needed.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT p.code), '{}')
  FROM   user_roles       ur
  JOIN   role_permissions  rp ON rp.role_id      = ur.role_id
  JOIN   permissions       p  ON p.id             = rp.permission_id
  WHERE  ur.profile_id        = auth.uid()
    AND  ur.is_active          = true
    AND  (ur.expires_at IS NULL OR ur.expires_at > now())
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes held by the current user. '
  'Reads role_permissions only — the Permission Matrix UI now writes directly '
  'to role_permissions (with target_group_id per row), so this is the single '
  'source of truth for both UI gates (can()) and RLS enforcement (user_can()).';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT proname,
       prosrc NOT LIKE '%permission_set_assignments%' AS no_longer_reads_sets
FROM   pg_proc
WHERE  proname = 'get_my_permissions';

-- =============================================================================
-- END OF MIGRATION 104
-- =============================================================================
