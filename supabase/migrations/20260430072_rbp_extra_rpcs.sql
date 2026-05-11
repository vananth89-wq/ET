-- =============================================================================
-- Migration 072: Extra RPCs for RBP Troubleshoot enhancements
--
-- Adds:
--   1. get_user_roles(p_profile_id uuid)
--      → Returns each active role with granted_at + assignment_source
--        (powers the "Since MMM YYYY" chip on the User Lookup tab)
--
--   2. get_users_by_permission(p_permission_code text)
--      → Reverse lookup: every user who holds a given permission,
--        with name, email, employee_id, and which role grants it
--        (powers the Permission Lookup tab)
--
-- Both require workflow.rbp_troubleshoot (SECURITY DEFINER).
-- =============================================================================


-- ── 1. get_user_roles ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_user_roles(p_profile_id uuid)
RETURNS TABLE (
  role_code          text,
  role_name          text,
  assignment_source  text,
  granted_at         timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  IF NOT has_permission('workflow.rbp_troubleshoot') THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  SELECT
    r.code                            AS role_code,
    r.name                            AS role_name,
    COALESCE(ur.assignment_source, 'manual') AS assignment_source,
    ur.granted_at                     AS granted_at
  FROM user_roles ur
  JOIN roles      r  ON r.id = ur.role_id
  WHERE ur.profile_id = p_profile_id
    AND ur.is_active  = true
    AND r.active      = true
  ORDER BY ur.granted_at ASC NULLS LAST;
END;
$$;

COMMENT ON FUNCTION get_user_roles(uuid) IS
  'Returns active roles for a user with granted_at timestamps. '
  'Requires workflow.rbp_troubleshoot. SECURITY DEFINER.';


-- ── 2. get_users_by_permission ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_users_by_permission(p_permission_code text)
RETURNS TABLE (
  profile_id    uuid,
  employee_id   text,
  name          text,
  email         text,
  designation   text,
  status        text,
  via_role_code text,
  via_role_name text,
  granted_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  IF NOT has_permission('workflow.rbp_troubleshoot') THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (pr.id, r.code)
    pr.id                             AS profile_id,
    e.employee_id                     AS employee_id,
    e.name                            AS name,
    COALESCE(e.business_email, '')    AS email,
    COALESCE(e.job_title, '')       AS designation,
    e.status::text                    AS status,
    r.code                            AS via_role_code,
    r.name                            AS via_role_name,
    ur.granted_at                     AS granted_at
  FROM permissions     p
  JOIN role_permissions rp  ON rp.permission_id = p.id
  JOIN roles            r   ON r.id             = rp.role_id AND r.active = true
  JOIN user_roles       ur  ON ur.role_id        = r.id      AND ur.is_active = true
  JOIN profiles         pr  ON pr.id             = ur.profile_id
  JOIN employees        e   ON e.id              = pr.employee_id
  WHERE p.code        = p_permission_code
    AND e.deleted_at  IS NULL
  ORDER BY pr.id, r.code, e.name;
END;
$$;

COMMENT ON FUNCTION get_users_by_permission(text) IS
  'Reverse lookup: all users who hold a given permission code, '
  'with the role that grants it. Requires workflow.rbp_troubleshoot. SECURITY DEFINER.';


-- ── VERIFICATION ──────────────────────────────────────────────────────────────
SELECT routine_name
FROM   information_schema.routines
WHERE  routine_name IN ('get_user_roles', 'get_users_by_permission')
  AND  routine_schema = 'public';
