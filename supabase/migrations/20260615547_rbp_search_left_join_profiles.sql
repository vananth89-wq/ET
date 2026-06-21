-- =============================================================================
-- Migration 547 — Fix search_users_for_rbp: LEFT JOIN profiles
--
-- ROOT CAUSE
-- ──────────
-- search_users_for_rbp uses INNER JOIN profiles → employees who have never
-- signed in (no auth.users row → no profiles row) are invisible to the search.
-- An admin searching for "Kiran" finds nothing even though the employee exists.
--
-- FIX
-- ───
-- Change JOIN to LEFT JOIN so all employees matching the query are returned.
-- profile_id becomes nullable in the result (NULL = employee has never logged in).
-- The frontend already handles null profile_id gracefully (no permission detail
-- can be shown for a user with no profile, but the card still renders).
-- =============================================================================

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
  LEFT JOIN profiles pr ON pr.employee_id = e.id   -- ← was INNER JOIN
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
  'Fixed in 547: LEFT JOIN profiles so employees without a login are still searchable.';
