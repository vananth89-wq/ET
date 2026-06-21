-- =============================================================================
-- Migration 502: Global Employee Search — RPCs
--
-- 1. search_employees(p_query, p_limit, p_include_inactive)
--    Permission-gated type-ahead search using pg_trgm + get_target_population.
--
-- 2. check_permission_for_target(p_module, p_action, p_target_employee_id)
--    Thin frontend-callable wrapper around user_can() for the canFor() hook.
--    Allows MyProfile to gate UI sections per-employee without exposing
--    user_can() directly (which is an internal function).
--
-- Key corrections vs design doc §4.1:
--   - Return columns use actual table names: employee_code → employee_id (TEXT),
--     full_name → name (TEXT), email → business_email (TEXT)
--   - get_target_population returns JSONB {mode, ids?} not UUID[] — handled below
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. search_employees
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION search_employees(
  p_query            TEXT,
  p_limit            INTEGER  DEFAULT 10,
  p_include_inactive BOOLEAN  DEFAULT false
)
RETURNS TABLE (
  employee_id     UUID,
  employee_code   TEXT,
  full_name       TEXT,
  email           TEXT,
  status          TEXT,
  manager_id      UUID,
  avatar_url      TEXT,
  similarity      REAL
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_query      TEXT;
  v_target     JSONB;
  v_target_ids UUID[];
BEGIN
  -- ── 1. Permission check ───────────────────────────────────────────────────
  IF NOT user_can('employee_search', 'view', NULL) THEN
    RAISE EXCEPTION 'Access denied: employee_search.view required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 2. Validate + sanitise query ─────────────────────────────────────────
  v_query := trim(lower(p_query));
  IF length(v_query) < 2 THEN
    RAISE EXCEPTION 'Search query must be at least 2 characters.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 3. Resolve target population ─────────────────────────────────────────
  -- employee_search.view is typically granted with an 'everyone' target group
  -- (v1 design — no population scoping). We honour whatever is configured.
  v_target := get_target_population('employee_search', 'view');

  IF v_target->>'mode' = 'none' THEN
    -- No access — return empty result set
    RETURN;
  END IF;

  IF v_target->>'mode' = 'scoped' THEN
    SELECT array_agg(elem::uuid)
    INTO   v_target_ids
    FROM   jsonb_array_elements_text(v_target->'ids') elem;
  END IF;

  -- ── 4. Query with trigram similarity ─────────────────────────────────────
  RETURN QUERY
  SELECT
    e.id                                        AS employee_id,
    e.employee_id                               AS employee_code,
    e.name                                      AS full_name,
    e.business_email                            AS email,
    e.status::text                              AS status,
    e.manager_id                                AS manager_id,
    e.photo_url                                 AS avatar_url,
    similarity(e.searchable_text, v_query)      AS similarity
  FROM   employees e
  WHERE  e.deleted_at IS NULL
    AND  e.searchable_text ILIKE '%' || v_query || '%'
    AND  (p_include_inactive OR e.status = 'Active')
    -- view_inactive guard: if caller doesn't have view_inactive, strip Inactive
    AND  (
           e.status = 'Active'
           OR p_include_inactive AND user_can('employee_search', 'view_inactive', NULL)
         )
    -- target population filter (mode=all → no filter; mode=scoped → id filter)
    AND  (v_target_ids IS NULL OR e.id = ANY(v_target_ids))
  ORDER  BY similarity(e.searchable_text, v_query) DESC,
            e.name ASC
  LIMIT  p_limit;
END;
$$;

COMMENT ON FUNCTION search_employees(text, integer, boolean) IS
  'Mig 502: Type-ahead employee search for the header search box. '
  'Requires employee_search.view permission. Uses pg_trgm GIN index on '
  'employees.searchable_text for sub-50ms performance on 500+ rows. '
  'p_include_inactive requires employee_search.view_inactive in addition. '
  'Target population honours get_target_population() result (mode=all|scoped|none).';

GRANT EXECUTE ON FUNCTION search_employees(text, integer, boolean) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. check_permission_for_target
--    Frontend canFor() hook calls this via supabase.rpc().
--    Returns TRUE if the current user has permission to perform p_action on
--    p_module for a specific target employee.
--
--    This is a direct delegation to user_can() — the same function used inside
--    all SECURITY DEFINER RPCs. Exposing it as a named RPC lets the frontend
--    build canFor(perm, targetId) without bypassing permission architecture.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_permission_for_target(
  p_module             TEXT,
  p_action             TEXT,
  p_target_employee_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Split p_module.p_action format if passed as a dotted string
  -- (convenience for callers using permission codes like 'personal_info.view')
  -- The caller may pass module + action separately OR as a dotted code.
  -- We accept both: if p_action is NULL, split p_module on '.'.
  IF p_action IS NULL OR p_action = '' THEN
    RETURN user_can(
      split_part(p_module, '.', 1),
      split_part(p_module, '.', 2),
      p_target_employee_id
    );
  END IF;

  RETURN user_can(p_module, p_action, p_target_employee_id);
END;
$$;

COMMENT ON FUNCTION check_permission_for_target(text, text, uuid) IS
  'Mig 502: Frontend-callable wrapper around user_can(module, action, target_employee_id). '
  'Used by the canFor(permissionCode, targetEmployeeId) React hook in MyProfile '
  'employee-mode to gate section visibility per-employee. '
  'Accepts module+action separately, or a dotted code (e.g. personal_info.view) '
  'with p_action=NULL.';

GRANT EXECUTE ON FUNCTION check_permission_for_target(text, text, uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  proname,
  pronargs,
  prosecdef
FROM pg_proc
WHERE proname IN ('search_employees', 'check_permission_for_target')
ORDER BY proname;

-- =============================================================================
-- END OF MIGRATION 502
-- =============================================================================
