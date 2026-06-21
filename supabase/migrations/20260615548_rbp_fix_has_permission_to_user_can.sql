-- =============================================================================
-- Migration 548 — Fix all RBP RPCs: replace has_permission() with user_can()
--
-- ROOT CAUSE
-- ──────────
-- All RBP RPCs (search_users_for_rbp, get_user_permissions, get_user_roles,
-- get_users_by_permission, explain_user_can) gate access with:
--   IF NOT has_permission('workflow.rbp_troubleshoot') THEN RAISE EXCEPTION
--
-- has_permission() was deprecated in mig 243 and is now a STUB that always
-- returns false. Every caller gets an exception → data=null → frontend shows
-- "No users found" silently.
--
-- Additionally, get_user_permissions and explain_user_can join role_permissions
-- which was DROPPED in mig 146. They would error on execution even if the gate
-- passed. Fixed here to use the live schema:
--   user_roles → permission_set_assignments → permission_set_items → permissions
--
-- FIX
-- ───
-- 1. Replace has_permission() with user_can('workflow', 'rbp_troubleshoot', NULL)
--    in all 5 RBP RPCs.
-- 2. Rewrite get_user_permissions to use permission_set_assignments/items.
-- 3. Rewrite explain_user_can to use permission_set_assignments/items.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. search_users_for_rbp  (also carries the LEFT JOIN fix from mig 547)
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF NOT user_can('workflow', 'rbp_troubleshoot', NULL) THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  SELECT
    pr.id                           AS profile_id,
    e.employee_id                   AS employee_id,
    e.name                          AS name,
    COALESCE(e.business_email, '')  AS email,
    COALESCE(e.job_title, '')       AS designation,
    e.status::text                  AS status,
    CASE
      WHEN pr.id IS NULL THEN '— (no login yet)'
      ELSE COALESCE(
        (SELECT string_agg(r.code, ', ' ORDER BY r.code)
         FROM user_roles ur2
         JOIN roles r ON r.id = ur2.role_id
         WHERE ur2.profile_id = pr.id AND ur2.is_active = true AND r.active = true),
        '—'
      )
    END                             AS role_codes
  FROM employees e
  LEFT JOIN profiles pr ON pr.employee_id = e.id
  WHERE e.deleted_at IS NULL
    AND (
      e.name              ILIKE '%' || p_query || '%'
      OR e.business_email ILIKE '%' || p_query || '%'
      OR e.employee_id    ILIKE '%' || p_query || '%'
    )
  ORDER BY e.name
  LIMIT 15;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_user_permissions  (gate fix + role_permissions → permission_set_*)
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF NOT user_can('workflow', 'rbp_troubleshoot', NULL) THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  WITH
  active_roles AS (
    SELECT r.code AS role_code, r.name AS role_name, r.id AS role_id
    FROM   user_roles ur
    JOIN   roles      r ON r.id = ur.role_id
    WHERE  ur.profile_id = p_profile_id
      AND  ur.is_active  = true
      AND  r.active      = true
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
    FROM   active_roles               ar
    JOIN   permission_set_assignments psa ON psa.role_id          = ar.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    GROUP BY m.code, m.name, m.sort_order, p.code, p.name, p.description
  )
  SELECT
    COALESCE(e.name,           'Unknown') AS user_name,
    COALESCE(e.business_email, '')        AS user_email,
    COALESCE(e.employee_id,    '')        AS user_employee_id,
    COALESCE(e.job_title,      '')        AS user_designation,
    COALESCE(e.status::text,   '')        AS user_status,
    COALESCE(rs.codes, '—')              AS role_codes,
    COALESCE(rs.names, '—')              AS role_names,
    up.mod_code,
    up.mod_name,
    up.mod_sort,
    up.perm_code,
    up.perm_name,
    up.perm_desc,
    up.via
  FROM   user_perms         up
  CROSS  JOIN role_summary  rs
  LEFT   JOIN profiles      pr ON pr.id        = p_profile_id
  LEFT   JOIN employees     e  ON e.id         = pr.employee_id
  ORDER BY up.mod_sort, up.mod_code, up.perm_code;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_user_roles  (gate fix only — body was already correct)
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF NOT user_can('workflow', 'rbp_troubleshoot', NULL) THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  SELECT
    r.code                                   AS role_code,
    r.name                                   AS role_name,
    COALESCE(ur.assignment_source, 'manual') AS assignment_source,
    ur.granted_at                            AS granted_at
  FROM user_roles ur
  JOIN roles      r ON r.id = ur.role_id
  WHERE ur.profile_id = p_profile_id
    AND ur.is_active  = true
    AND r.active      = true
  ORDER BY ur.granted_at ASC NULLS LAST;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_users_by_permission  (gate fix only — body was correct)
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF NOT user_can('workflow', 'rbp_troubleshoot', NULL) THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (pr.id, r.code)
    pr.id                             AS profile_id,
    e.employee_id                     AS employee_id,
    e.name                            AS name,
    COALESCE(e.business_email, '')    AS email,
    COALESCE(e.job_title,      '')    AS designation,
    e.status::text                    AS status,
    r.code                            AS via_role_code,
    r.name                            AS via_role_name,
    ur.granted_at                     AS granted_at
  FROM   permissions                p
  JOIN   permission_set_items       psi ON psi.permission_id    = p.id
  JOIN   permission_set_assignments psa ON psa.permission_set_id = psi.permission_set_id
  JOIN   roles                      r   ON r.id                 = psa.role_id AND r.active = true
  JOIN   user_roles                 ur  ON ur.role_id           = r.id        AND ur.is_active = true
  JOIN   profiles                   pr  ON pr.id                = ur.profile_id
  JOIN   employees                  e   ON e.id                 = pr.employee_id
  WHERE  p.code       = p_permission_code
    AND  e.deleted_at IS NULL
  ORDER BY pr.id, r.code, e.name;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. explain_user_can  (gate fix + role_permissions → permission_set_*)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION explain_user_can(
  p_profile_id uuid,
  p_module     text,
  p_action     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
  v_perm_code text := p_module || '.' || p_action;
BEGIN
  IF NOT user_can('workflow', 'rbp_troubleshoot', NULL) THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  SELECT jsonb_build_object(
    'profile_id',       p_profile_id,
    'permission_code',  v_perm_code,
    'granted',          bool_or(p.code IS NOT NULL),
    'via_roles', COALESCE(
      jsonb_agg(DISTINCT jsonb_build_object(
        'role_code', r.code,
        'role_name', r.name
      )) FILTER (WHERE r.code IS NOT NULL),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM   user_roles                 ur
  JOIN   roles                      r   ON r.id                  = ur.role_id  AND r.active = true
  JOIN   permission_set_assignments psa ON psa.role_id           = r.id
  JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
  JOIN   permissions                p   ON p.id                  = psi.permission_id AND p.code = v_perm_code
  WHERE  ur.profile_id = p_profile_id
    AND  ur.is_active  = true;

  RETURN COALESCE(v_result, jsonb_build_object(
    'profile_id',      p_profile_id,
    'permission_code', v_perm_code,
    'granted',         false,
    'via_roles',       '[]'::jsonb
  ));
END;
$$;

COMMENT ON FUNCTION search_users_for_rbp(text)          IS 'Fixed mig 548: user_can gate + LEFT JOIN profiles.';
COMMENT ON FUNCTION get_user_permissions(uuid)          IS 'Fixed mig 548: user_can gate + permission_set_* joins.';
COMMENT ON FUNCTION get_user_roles(uuid)                IS 'Fixed mig 548: user_can gate.';
COMMENT ON FUNCTION get_users_by_permission(text)       IS 'Fixed mig 548: user_can gate + permission_set_* joins.';
COMMENT ON FUNCTION explain_user_can(uuid, text, text)  IS 'Fixed mig 548: user_can gate + permission_set_* joins.';

-- Also fix the frontend search error-handling gap:
-- The frontend swallows RPC errors silently (data ?? [] = []).
-- This migration ensures the RPCs no longer throw for valid callers,
-- so no frontend change is needed for the gate fix.
-- The null profile_id guard added in the previous session (RbpTroubleshoot.tsx)
-- handles the LEFT JOIN case correctly.
