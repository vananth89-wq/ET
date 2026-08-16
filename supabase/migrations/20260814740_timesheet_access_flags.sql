-- Migration : 20260814740_timesheet_access_flags.sql
-- Purpose   : Let a screen ask, per employee, "may I open this person's
--             timesheet, and may I change it?" — and get the same answer the
--             database will give when it tries.
--
-- WHY THIS AND NOT A CLIENT-SIDE CHECK
--   The client holds a FLAT list of permission codes: it knows the signed-in
--   user has `timesheet.edit`, and cannot know that the grant is scoped to
--   Direct Reports (L1). Asking `can('timesheet.edit')` in the browser
--   therefore answers a different question from the one RLS and the three write
--   RPCs answer, and it answers it wrongly in both directions -- offering Edit
--   on an employee outside the scope, and hiding it from a manager who does
--   hold it. Scope lives in target groups, and only user_can() reads them.
--
--   So the answer comes from user_can(), per employee, and the UI is exactly as
--   permissive as the database. When an administrator changes a permission set
--   or a target group, the next page load reflects it with no deploy. That is
--   the point: permissions are admin-controlled and can change at any time, and
--   nothing in the UI may bake in an assumption about who a role is.
--
-- TWO CALLERS, TWO SHAPES
--   search_employees   -- a flag per result row, so a "View Timesheet" action
--                         appears only where it will work. The search result
--                         set is scoped by employee_search.view, which is a
--                         DIFFERENT scope from timesheet.view: HR Analyst can
--                         search the whole org and holds no timesheet
--                         permission at all. Without the flag they would get a
--                         button that leads to a refusal.
--   time_timesheet_access -- the whole answer for one employee, for the
--                         timesheet page itself to decide read-only vs editable.
--
-- Depends on : 084 (user_can), 520 (search_employees), 739

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the per-employee answer, in one place
-- ═══════════════════════════════════════════════════════════════════════════
-- Every consumer reads this rather than composing its own user_can() calls, so
-- "what may I do to this timesheet" has exactly one definition. The action
-- names match the ones RLS and the RPCs check -- timesheet.view / edit / delete
-- -- because a screen that asks about a different permission from the one
-- enforced is section N of the test plan all over again.

CREATE OR REPLACE FUNCTION public.time_timesheet_access(p_employee_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT jsonb_build_object(
    'employee_id', p_employee_id,
    'can_view',    user_can('timesheet', 'view',   p_employee_id),
    'can_edit',    user_can('timesheet', 'edit',   p_employee_id),
    'can_delete',  user_can('timesheet', 'delete', p_employee_id),
    'can_create',  user_can('timesheet', 'create', p_employee_id)
  );
$fn$;

REVOKE ALL ON FUNCTION public.time_timesheet_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_timesheet_access(uuid) TO authenticated;

COMMENT ON FUNCTION public.time_timesheet_access(uuid) IS
  'MIG 740 - what the caller may do to this employee''s timesheet, straight '
  'from user_can so the UI cannot disagree with RLS. The client permission list '
  'is flat and cannot answer this: scope lives in target groups.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the same answer as a column on the search results
-- ═══════════════════════════════════════════════════════════════════════════
-- DROP and recreate rather than CREATE OR REPLACE: Postgres refuses to change
-- the return type of an existing function, and this adds two output columns.
-- The body is otherwise the live one verbatim -- the gate, the target
-- population, the scope filter and the ordering are untouched.
--
-- The two flags are computed for the rows that survive the LIMIT, not for the
-- whole table, so this costs a handful of user_can() calls per keystroke.

DROP FUNCTION IF EXISTS public.search_employees(text, integer, boolean);

CREATE FUNCTION public.search_employees(
  p_query            text,
  p_limit            integer DEFAULT 10,
  p_include_inactive boolean DEFAULT false
)
RETURNS TABLE(
  employee_id   uuid,
  employee_code text,
  full_name     text,
  email         text,
  status        text,
  manager_id    uuid,
  avatar_url    text,
  similarity    real,
  -- MIG 740. Named for what the caller may DO, not for a role.
  can_view_timesheet boolean,
  can_edit_timesheet boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
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
    similarity(e.searchable_text, v_query)      AS similarity,
    user_can('timesheet', 'view', e.id)         AS can_view_timesheet,
    user_can('timesheet', 'edit', e.id)         AS can_edit_timesheet
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
$fn$;

REVOKE ALL ON FUNCTION public.search_employees(text, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_employees(text, integer, boolean) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — assert the shape
-- ═══════════════════════════════════════════════════════════════════════════
-- ::text casts: text[] || 'literal' resolves to array || array and dies with
-- "malformed array literal" instead of reporting anything. See mig 738.

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'search_employees';

  IF v_src IS NULL THEN
    v_missing := v_missing || 'mig 740: search_employees is gone'::text;
  ELSE
    IF position('can_view_timesheet' IN v_src) = 0 THEN
      v_missing := v_missing || 'mig 740: the per-row timesheet flags'::text; END IF;
    -- The three things the rewrite must not have dropped.
    IF position('user_can(''employee_search'', ''view'', NULL)' IN v_src) = 0 THEN
      v_missing := v_missing || 'REGRESSION: the search permission gate is gone'::text; END IF;
    IF position('get_target_population' IN v_src) = 0 THEN
      v_missing := v_missing || 'REGRESSION: population scoping is gone from search_employees'::text; END IF;
    IF position('v_target_ids IS NULL OR e.id = ANY(v_target_ids)' IN v_src) = 0 THEN
      v_missing := v_missing || 'REGRESSION: the scope filter is gone from the WHERE clause'::text; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'time_timesheet_access'
                   AND p.prosecdef) THEN
    v_missing := v_missing || 'mig 740: the access helper is missing or not SECURITY DEFINER'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 740 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 740 verified: per-employee timesheet access, on the row and on its own.';
END $mig$;

COMMIT;
