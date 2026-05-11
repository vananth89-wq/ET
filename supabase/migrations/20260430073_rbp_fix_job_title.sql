-- =============================================================================
-- Migration 073: Fix RBP RPCs — use job_title instead of designation
--
-- employees.designation stores a picklist UUID, not display text.
-- employees.job_title is the human-readable label (e.g. "Consultant").
-- Patch all three RBP RPCs to use job_title.
-- =============================================================================


-- ── 1. get_user_permissions ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_user_permissions(p_profile_id uuid)
RETURNS TABLE (
  user_name         text,
  user_email        text,
  user_employee_id  text,
  user_designation  text,
  user_status       text,
  role_codes        text,
  role_names        text,
  module_code       text,
  module_name       text,
  module_sort       int,
  permission_code   text,
  permission_name   text,
  permission_desc   text,
  via_roles         text
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
  WITH
  active_roles AS (
    SELECT r.code AS role_code, r.name AS role_name, r.id AS role_id
    FROM user_roles ur
    JOIN roles      r ON r.id = ur.role_id
    WHERE ur.profile_id = p_profile_id
      AND ur.is_active  = true
      AND r.active      = true
  ),
  role_summary AS (
    SELECT
      string_agg(role_code, ', ' ORDER BY role_code) AS codes,
      string_agg(role_name, ', ' ORDER BY role_code) AS names
    FROM active_roles
  ),
  user_perms AS (
    SELECT
      m.code                          AS mod_code,
      m.name                          AS mod_name,
      COALESCE(m.sort_order, 99)      AS mod_sort,
      p.code                          AS perm_code,
      p.name                          AS perm_name,
      p.description                   AS perm_desc,
      string_agg(ar.role_code, ', ' ORDER BY ar.role_code) AS via
    FROM active_roles      ar
    JOIN role_permissions  rp ON rp.role_id     = ar.role_id
    JOIN permissions       p  ON p.id           = rp.permission_id
    JOIN modules           m  ON m.id           = p.module_id
    GROUP BY m.code, m.name, m.sort_order, p.code, p.name, p.description
  )
  SELECT
    COALESCE(e.name,           'Unknown') AS user_name,
    COALESCE(e.business_email, '')        AS user_email,
    COALESCE(e.employee_id,    '')        AS user_employee_id,
    COALESCE(e.job_title,      '')        AS user_designation,   -- job_title = display text
    COALESCE(e.status::text,   '')        AS user_status,
    COALESCE(rs.codes, '—')             AS role_codes,
    COALESCE(rs.names, '—')             AS role_names,
    up.mod_code,
    up.mod_name,
    up.mod_sort,
    up.perm_code,
    up.perm_name,
    up.perm_desc,
    up.via
  FROM user_perms          up
  CROSS JOIN role_summary  rs
  LEFT  JOIN profiles      pr ON pr.id          = p_profile_id
  LEFT  JOIN employees     e  ON e.id           = pr.employee_id
  ORDER BY up.mod_sort, up.mod_code, up.perm_code;
END;
$$;


-- ── 2. search_users_for_rbp ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION search_users_for_rbp(p_query text)
RETURNS TABLE (
  profile_id   uuid,
  employee_id  text,
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
    COALESCE(e.job_title, '')       AS designation,   -- job_title = display text
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


-- ── 3. get_users_by_permission ────────────────────────────────────────────────

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
    COALESCE(e.job_title, '')         AS designation,   -- job_title = display text
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

COMMENT ON FUNCTION get_user_permissions(uuid)      IS 'Fixed in 073: uses job_title for display.';
COMMENT ON FUNCTION search_users_for_rbp(text)      IS 'Fixed in 073: uses job_title for display.';
COMMENT ON FUNCTION get_users_by_permission(text)   IS 'Fixed in 073: uses job_title for display.';
