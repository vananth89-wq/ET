-- =============================================================================
-- Migration 510: Fix search_employees — employees.photo_url was dropped in mig 020
-- Return NULL for avatar_url; photo is on employee_personal satellite.
-- =============================================================================
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
  IF NOT user_can('employee_search', 'view', NULL) THEN
    RAISE EXCEPTION 'Access denied: employee_search.view required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_query := trim(lower(p_query));
  IF length(v_query) < 2 THEN
    RAISE EXCEPTION 'Search query must be at least 2 characters.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_target := get_target_population('employee_search', 'view');

  IF v_target->>'mode' = 'none' THEN
    RETURN;
  END IF;

  IF v_target->>'mode' = 'scoped' THEN
    SELECT array_agg(elem::uuid)
    INTO   v_target_ids
    FROM   jsonb_array_elements_text(v_target->'ids') elem;
  END IF;

  RETURN QUERY
  SELECT
    e.id                                        AS employee_id,
    e.employee_id                               AS employee_code,
    e.name                                      AS full_name,
    e.business_email                            AS email,
    e.status::text                              AS status,
    e.manager_id                                AS manager_id,
    NULL::text                                  AS avatar_url,   -- photo_url lives on employee_personal
    similarity(e.searchable_text, v_query)      AS similarity
  FROM   employees e
  WHERE  e.deleted_at IS NULL
    AND  e.searchable_text ILIKE '%' || v_query || '%'
    AND  (
           e.status = 'Active'
           OR (p_include_inactive AND user_can('employee_search', 'view_inactive', NULL))
         )
    AND  (v_target_ids IS NULL OR e.id = ANY(v_target_ids))
  ORDER  BY similarity(e.searchable_text, v_query) DESC,
            e.name ASC
  LIMIT  p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION search_employees(text, integer, boolean) TO authenticated;
-- =============================================================================
