-- =============================================================================
-- Migration 071: RBP Troubleshooting permission + RPC
--
-- Adds:
--   1. workflow.rbp_troubleshoot permission (Workflow Engine module)
--      → Granted to admin role by default; admin can extend via Permissions UI
--
--   2. get_user_permissions(p_profile_id uuid)
--      → SECURITY DEFINER RPC — caller must have workflow.rbp_troubleshoot
--      → Returns full permission breakdown for any user:
--         profile info, active roles, every permission + module + granting role(s)
--
--   3. search_users_for_rbp(p_query text)
--      → SECURITY DEFINER RPC — same permission gate
--      → Returns matching employees+profiles for the search autocomplete
-- =============================================================================


-- ── 1. Add the permission ──────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT
  'workflow.rbp_troubleshoot',
  'RBP Troubleshooting',
  'View the full role and permission breakdown for any user. '
  'Use to diagnose access issues without needing direct DB access.',
  m.id,
  50
FROM modules m
WHERE m.code = 'workflow'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order;

-- Grant to admin only by default
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r
CROSS JOIN permissions p
WHERE  r.code = 'admin'
  AND  p.code = 'workflow.rbp_troubleshoot'
ON CONFLICT DO NOTHING;


-- ── 2. get_user_permissions RPC ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_user_permissions(p_profile_id uuid)
RETURNS TABLE (
  -- user summary (one row repeated, but convenient for frontend)
  user_name         text,
  user_email        text,
  user_employee_id  text,    -- the human-readable ID like E001
  user_designation  text,
  user_status       text,
  -- role info
  role_codes        text,    -- comma-separated active role codes
  role_names        text,    -- comma-separated active role names
  -- permission row
  module_code       text,
  module_name       text,
  module_sort       int,
  permission_code   text,
  permission_name   text,
  permission_desc   text,
  via_roles         text     -- comma-separated role codes that grant this permission
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  -- Gate: caller must have workflow.rbp_troubleshoot
  IF NOT has_permission('workflow.rbp_troubleshoot') THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  WITH
  -- Active roles for the target user
  active_roles AS (
    SELECT
      r.code  AS role_code,
      r.name  AS role_name,
      r.id    AS role_id
    FROM user_roles ur
    JOIN roles      r  ON r.id = ur.role_id
    WHERE ur.profile_id = p_profile_id
      AND ur.is_active  = true
      AND r.active      = true
  ),

  -- Role summary strings
  role_summary AS (
    SELECT
      string_agg(role_code, ', ' ORDER BY role_code) AS codes,
      string_agg(role_name, ', ' ORDER BY role_code) AS names
    FROM active_roles
  ),

  -- All permissions granted through those roles
  user_perms AS (
    SELECT
      m.code                AS mod_code,
      m.name                AS mod_name,
      COALESCE(m.sort_order, 99) AS mod_sort,
      p.code                AS perm_code,
      p.name                AS perm_name,
      p.description         AS perm_desc,
      string_agg(ar.role_code, ', ' ORDER BY ar.role_code) AS via
    FROM active_roles       ar
    JOIN role_permissions   rp  ON rp.role_id     = ar.role_id
    JOIN permissions        p   ON p.id           = rp.permission_id
    JOIN modules            m   ON m.id           = p.module_id
    GROUP BY m.code, m.name, m.sort_order, p.code, p.name, p.description
  )

  SELECT
    COALESCE(e.name,          'Unknown')  AS user_name,
    COALESCE(e.business_email,'')         AS user_email,
    COALESCE(e.employee_id,   '')         AS user_employee_id,
    COALESCE(e.job_title,   '')         AS user_designation,
    COALESCE(e.status::text,  '')         AS user_status,
    COALESCE(rs.codes, '—')              AS role_codes,
    COALESCE(rs.names, '—')              AS role_names,
    up.mod_code,
    up.mod_name,
    up.mod_sort,
    up.perm_code,
    up.perm_name,
    up.perm_desc,
    up.via
  FROM user_perms          up
  CROSS JOIN role_summary  rs
  LEFT  JOIN profiles      pr  ON pr.id          = p_profile_id
  LEFT  JOIN employees     e   ON e.id           = pr.employee_id
  ORDER BY up.mod_sort, up.mod_code, up.perm_code;
END;
$$;

COMMENT ON FUNCTION get_user_permissions(uuid) IS
  'Returns the full permission breakdown for a user (profile_id). '
  'Caller must hold workflow.rbp_troubleshoot. SECURITY DEFINER.';


-- ── 3. search_users_for_rbp RPC ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION search_users_for_rbp(p_query text)
RETURNS TABLE (
  profile_id   uuid,
  employee_id  text,    -- human-readable E001
  name         text,
  email        text,
  designation  text,
  status       text,
  role_codes   text
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
    pr.id                           AS profile_id,
    e.employee_id                   AS employee_id,
    e.name                          AS name,
    COALESCE(e.business_email, '')  AS email,
    COALESCE(e.job_title, '')     AS designation,
    e.status::text                  AS status,
    COALESCE(
      (SELECT string_agg(r.code, ', ' ORDER BY r.code)
       FROM user_roles ur2
       JOIN roles r ON r.id = ur2.role_id
       WHERE ur2.profile_id = pr.id AND ur2.is_active = true AND r.active = true),
      '—'
    )                               AS role_codes
  FROM employees e
  JOIN profiles  pr ON pr.employee_id = e.id
  WHERE e.deleted_at IS NULL
    AND (
      e.name           ILIKE '%' || p_query || '%'
      OR e.business_email ILIKE '%' || p_query || '%'
      OR e.employee_id    ILIKE '%' || p_query || '%'
    )
  ORDER BY e.name
  LIMIT 15;
END;
$$;

COMMENT ON FUNCTION search_users_for_rbp(text) IS
  'Autocomplete search for the RBP Troubleshoot screen. '
  'Returns matching employees+profiles. Requires workflow.rbp_troubleshoot.';


-- ── VERIFICATION ──────────────────────────────────────────────────────────────
SELECT code, name, sort_order
FROM   permissions
WHERE  code = 'workflow.rbp_troubleshoot';
