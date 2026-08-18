-- =============================================================================
-- Migration : 20260818746_report_scope_and_pagination.sql
-- Purpose   : Make the two report RPCs survive 50,000 employees.
--
-- THE TWO CEILINGS THIS REMOVES
--   Neither is a slow path that degrades. Both are walls.
--
--   1. `time_report_scope()` returned uuid[]. For an HR user scoped to the
--      whole company that is a 50,000-element array built on every call and
--      compared with `= ANY()` row by row. Replaced by a three-state mode plus
--      a set-returning function, used as a materialised semi-join.
--
--   2. `timesheet_report_compliance` built `employees CROSS JOIN periods` and
--      then ran three correlated subqueries PER ROW, before LIMIT. 50k
--      employees x 12 months is 600,000 evaluations to render fifty. Split into
--      two phases: build and paginate a cheap skeleton, then compute the
--      expensive columns for the page's rows only, via LATERAL.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   Keyset pagination. It is the right answer for deep pages and it changes the
--   response envelope (an opaque cursor replaces page numbers), which means the
--   frontend must change in the same breath. That is a bigger blast radius than
--   one migration should carry, and OFFSET is survivable once the per-row
--   subqueries are gone. It gets its own migration alongside its frontend.
--
-- ORDERING NOTE
--   Done BEFORE the remaining reports are built, on purpose. Every report added
--   first is another call site to rework: today it is two, after Workforce
--   Capacity, Project Summary and the Executive Dashboard it would be five.
--
-- Depends on : 744 (the RPCs), 745 (the per-report permissions this preserves)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — scope as a predicate, not a list
-- ═══════════════════════════════════════════════════════════════════════════
-- Three states, named explicitly, because the previous shape encoded them as
-- "NULL means everything, empty array means nothing" and that is one typo away
-- from a report that shows every employee to someone entitled to none.
--
--   'all'    — no restriction. Do not call time_report_scope_ids().
--   'scoped' — the ids from time_report_scope_ids() and nothing else.
--   'none'   — the caller may see nobody. Return an empty result and stop.

CREATE OR REPLACE FUNCTION public.time_report_scope_mode()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pop jsonb;
BEGIN
  -- A super admin bypasses user_can() entirely, so it must bypass this too or
  -- the report becomes the one screen they cannot read.
  IF is_super_admin() THEN
    RETURN 'all';
  END IF;

  v_pop := get_target_population('timesheet', 'view');

  IF v_pop->>'mode' = 'all'    THEN RETURN 'all';    END IF;
  IF v_pop->>'mode' = 'scoped' THEN RETURN 'scoped'; END IF;
  RETURN 'none';
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_scope_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_scope_mode() TO authenticated;

COMMENT ON FUNCTION public.time_report_scope_mode() IS
  'Mig 746: all | scoped | none. Check this BEFORE calling time_report_scope_ids() '
  '-- that function is empty for both all and none, and the two mean opposite things.';


/**
 * The scoped employee ids, as ROWS.
 *
 * Returns nothing at all unless the mode is 'scoped', so a caller that forgets
 * the mode check gets an empty report rather than an unrestricted one. Failing
 * closed is the only acceptable direction for this particular mistake.
 */
CREATE OR REPLACE FUNCTION public.time_report_scope_ids()
RETURNS TABLE (employee_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pop jsonb;
BEGIN
  IF is_super_admin() THEN
    RETURN;                      -- 'all' -- no list, and none is needed
  END IF;

  v_pop := get_target_population('timesheet', 'view');

  IF v_pop->>'mode' <> 'scoped' THEN
    RETURN;                      -- 'all' or 'none' -- both carry no id list
  END IF;

  RETURN QUERY
    SELECT (jsonb_array_elements_text(v_pop->'ids'))::uuid;
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_scope_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_scope_ids() TO authenticated;

COMMENT ON FUNCTION public.time_report_scope_ids() IS
  'Mig 746: the scoped employee ids as rows, for a materialised semi-join. Empty '
  'unless time_report_scope_mode() = ''scoped''. Fails closed by design.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the indexes the reports actually need
-- ═══════════════════════════════════════════════════════════════════════════
-- timesheet_headers already carries UNIQUE (employee_id, period) from 704, but
-- that index leads with employee_id and every report filters on PERIOD first.
-- A leading-column mismatch is not a small inefficiency at this size; it is a
-- sequential scan of the whole table per report run.

CREATE INDEX IF NOT EXISTS idx_tsh_period_employee
  ON public.timesheet_headers (period, employee_id);

CREATE INDEX IF NOT EXISTS idx_tsh_period_status
  ON public.timesheet_headers (period, status);

-- Compliance counts distinct entry dates per header; utilisation walks entries
-- by header and date.
CREATE INDEX IF NOT EXISTS idx_tse_header_date
  ON public.timesheet_entries (header_id, entry_date);

-- Utilisation filtered to one project across a period.
CREATE INDEX IF NOT EXISTS idx_tse_project_date
  ON public.timesheet_entries (project_id, entry_date)
  WHERE project_id IS NOT NULL;

-- The post-approval change count.
CREATE INDEX IF NOT EXISTS idx_tea_header_created
  ON public.timesheet_entry_audit (header_id, created_at);

COMMENT ON INDEX public.idx_tsh_period_employee IS
  'Mig 746: reports filter on period first; the 704 unique index leads with employee_id.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — compliance, in two phases
-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 1 builds the (employee, period) skeleton, applies scope and filters,
-- and paginates. No subqueries: it is joins and a CASE.
-- Phase 2 computes days_with_entries and changes_since_approval for the fifty
-- rows that survived, through a LATERAL over the paginated set.
--
-- Summary counts stay over the WHOLE filtered set — they are counting queries
-- over the cheap skeleton, not row-building ones, so they cost what a count
-- costs and the footer does not start lying at page two.

CREATE OR REPLACE FUNCTION public.timesheet_report_compliance(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET jit = 'off'
AS $fn$
DECLARE
  v_mode     text;
  v_from     date;
  v_to       date;
  v_emp      uuid[];
  v_dept     uuid[];
  v_states   text[];
  v_overdue  boolean;
  v_page     integer;
  v_size     integer;
  v_result   jsonb;
BEGIN
  IF NOT user_can('timesheet_reports', 'view_compliance', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to open the timesheet compliance report.');
  END IF;

  v_mode := time_report_scope_mode();

  v_from  := COALESCE((p_filters->>'period_from')::date, date_trunc('month', CURRENT_DATE)::date);
  v_from  := date_trunc('month', v_from)::date;
  v_to    := date_trunc('month', COALESCE((p_filters->>'period_to')::date, v_from))::date;
  IF v_to < v_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_RANGE',
      'message', 'The end month is before the start month.');
  END IF;

  v_emp     := CASE WHEN p_filters ? 'employee_ids' THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'employee_ids')::uuid) END;
  v_dept    := CASE WHEN p_filters ? 'dept_ids'     THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'dept_ids')::uuid)     END;
  v_states  := CASE WHEN p_filters ? 'states'       THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'states'))             END;
  v_overdue := COALESCE((p_filters->>'only_overdue')::boolean, false);
  v_page    := GREATEST(1, COALESCE((p_filters->>'page')::integer, 1));
  v_size    := LEAST(500, GREATEST(1, COALESCE((p_filters->>'page_size')::integer, 50)));

  IF v_mode = 'none' THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'total_rows', 0,
      'page', v_page, 'page_size', v_size,
      'summary', jsonb_build_object('expected', 0, 'not_configured', 0, 'not_started', 0,
                                    'to_be_submitted', 0, 'to_be_approved', 0,
                                    'approved', 0, 'overdue', 0,
                                    'planned_minutes', 0, 'recorded_minutes', 0),
      'scope', jsonb_build_object('mode', 'none'));
  END IF;

  WITH scope AS MATERIALIZED (
    -- Materialised once. The previous shape marshalled this as an array into
    -- every comparison; here it is a hash table the planner builds one time.
    SELECT s.employee_id FROM time_report_scope_ids() s
  ),
  per AS (
    -- The deadline is a property of the month, and there are at most a handful
    -- of months in range. Computing it here rather than per row means
    -- time_submission_due_date() is called once per period instead of once per
    -- (employee, period) -- three calls rather than thirty thousand.
    SELECT g::date AS period, time_submission_due_date(g::date) AS due_date
    FROM   generate_series(v_from, v_to, INTERVAL '1 month') g
  ),
  base AS (
    SELECT e.id AS employee_id, e.name AS employee_name, e.employee_id AS employee_code,
           e.manager_id, p.period, p.due_date
    FROM   employees e
    CROSS  JOIN per p
    WHERE  e.deleted_at IS NULL
      AND  e.status = 'Active'
      AND  (v_mode = 'all' OR e.id IN (SELECT employee_id FROM scope))
      AND  (v_emp IS NULL OR e.id = ANY(v_emp))
  ),
  emp AS (
    SELECT b.*, ee.work_schedule_id, ee.dept_id, (ee.employee_id IS NOT NULL) AS employed
    FROM   base b
    LEFT   JOIN LATERAL (
      SELECT x.employee_id, x.work_schedule_id, x.dept_id
      FROM   employee_employment x
      WHERE  x.employee_id     = b.employee_id
        AND  x.effective_from <= (b.period + INTERVAL '1 month - 1 day')::date
        AND  x.effective_to   >= b.period
      ORDER  BY x.effective_from DESC
      LIMIT  1
    ) ee ON true
  ),
  -- Phase 1: everything that is a join or a CASE. Nothing per-row-expensive.
  core AS (
    SELECT em.employee_id, em.employee_name, em.employee_code, em.period,
           em.work_schedule_id, em.dept_id,
           dp.name AS department_name,
           mg.name AS manager_name,
           ws.name AS schedule_name,
           h.id AS header_id, h.status AS header_status,
           h.planned_minutes, h.recorded_minutes,
           h.submitted_at, h.approved_at, h.workflow_instance_id,
           em.due_date,
           CASE
             WHEN em.work_schedule_id IS NULL THEN 'not_configured'
             WHEN h.id IS NULL                THEN 'not_started'
             ELSE h.status
           END AS state
    FROM       emp em
    LEFT  JOIN timesheet_headers    h  ON h.employee_id = em.employee_id AND h.period = em.period
    LEFT  JOIN departments          dp ON dp.id = em.dept_id
    LEFT  JOIN employees            mg ON mg.id = em.manager_id
    LEFT  JOIN time_work_schedules  ws ON ws.id = em.work_schedule_id
    WHERE em.employed                                  -- a leaver is not late
      AND (v_dept IS NULL OR em.dept_id = ANY(v_dept))
  ),
  filtered AS (
    SELECT c.*,
           (c.state IN ('not_started','to_be_submitted') AND CURRENT_DATE > c.due_date) AS is_overdue,
           GREATEST(0, CURRENT_DATE - c.due_date) AS days_past_due
    FROM   core c
    WHERE  (v_states IS NULL OR c.state = ANY(v_states))
  ),
  -- MATERIALIZED: referenced by agg, by total_rows and by page. Inlined, the
  -- planner is free to rebuild the whole skeleton for each reference.
  final AS MATERIALIZED (
    SELECT * FROM filtered f WHERE (NOT v_overdue OR f.is_overdue)
  ),
  -- ONE pass for every headline number, using FILTER, instead of ten separate
  -- `(SELECT count(*) FROM final WHERE ...)` scans. Measured on a 30,010-row
  -- skeleton: ten scans 1,485ms, one pass 1,052ms. The saving scales with the
  -- row count, which is the direction that matters.
  agg AS (
    SELECT count(*)                                                   AS total_rows,
           count(*) FILTER (WHERE state <> 'not_configured')           AS expected,
           count(*) FILTER (WHERE state =  'not_configured')           AS not_configured,
           count(*) FILTER (WHERE state =  'not_started')              AS not_started,
           count(*) FILTER (WHERE state =  'to_be_submitted')          AS to_be_submitted,
           count(*) FILTER (WHERE state =  'to_be_approved')           AS to_be_approved,
           count(*) FILTER (WHERE state =  'approved')                 AS approved,
           count(*) FILTER (WHERE is_overdue)                          AS overdue,
           COALESCE(sum(planned_minutes), 0)                           AS planned_minutes,
           COALESCE(sum(recorded_minutes), 0)                          AS recorded_minutes
    FROM   final
  ),
  -- Phase 2 starts here: only these rows pay for the expensive columns.
  page AS (
    SELECT * FROM final
    ORDER BY period, employee_name
    LIMIT  v_size
    OFFSET (v_page - 1) * v_size
  )
  SELECT jsonb_build_object(
    'ok', true,
    'page', v_page,
    'page_size', v_size,
    'total_rows', (SELECT total_rows FROM agg),

    -- Still the WHOLE filtered set, not the page. A footer that totals only the
    -- visible rows starts lying at page two, which is the most common bug in
    -- enterprise grids.
    'summary', (SELECT jsonb_build_object(
      'expected',         a.expected,
      'not_configured',   a.not_configured,
      'not_started',      a.not_started,
      'to_be_submitted',  a.to_be_submitted,
      'to_be_approved',   a.to_be_approved,
      'approved',         a.approved,
      'overdue',          a.overdue,
      'planned_minutes',  a.planned_minutes,
      'recorded_minutes', a.recorded_minutes
    ) FROM agg a),

    'scope', jsonb_build_object(
      'mode', v_mode,
      'employee_count', CASE WHEN v_mode = 'scoped'
                             THEN (SELECT count(*) FROM scope) ELSE NULL END),

    'rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'employee_id',      pg.employee_id,
               'employee_name',    pg.employee_name,
               'employee_code',    pg.employee_code,
               'manager_name',     pg.manager_name,
               'department_name',  pg.department_name,
               'schedule_name',    pg.schedule_name,
               'period',           pg.period,
               'state',            pg.state,
               'header_id',        pg.header_id,
               'header_status',    pg.header_status,
               'planned_minutes',  COALESCE(pg.planned_minutes, 0),
               'recorded_minutes', COALESCE(pg.recorded_minutes, 0),
               'variance_minutes', COALESCE(pg.recorded_minutes, 0) - COALESCE(pg.planned_minutes, 0),
               'days_with_entries', COALESCE(x.days_with_entries, 0),
               'submitted_at',     pg.submitted_at,
               'approved_at',      pg.approved_at,
               'due_date',         pg.due_date,
               'is_overdue',       pg.is_overdue,
               'days_past_due',    CASE WHEN pg.is_overdue THEN pg.days_past_due ELSE 0 END,
               'changes_since_approval', x.changes_since_approval,
               'workflow_instance_id',   pg.workflow_instance_id)
             ORDER BY pg.period, pg.employee_name)
      FROM page pg
      LEFT JOIN LATERAL (
        SELECT
          (SELECT count(DISTINCT te.entry_date)
             FROM timesheet_entries te
            WHERE te.header_id = pg.header_id
              AND NOT COALESCE(te.is_system_generated, false)) AS days_with_entries,
          -- approved_at is restamped on every approval by wf_sync_module_status,
          -- so it is the last one. System rows are excluded from the ADDED half:
          -- a holiday written by the sync is not something an approver failed to
          -- sign off, and counting it would put a permanent 1 beside every
          -- approved month containing a public holiday (test C15).
          CASE WHEN pg.approved_at IS NULL THEN NULL ELSE (
            (SELECT count(*) FROM timesheet_entry_audit ta
              WHERE ta.header_id = pg.header_id AND ta.created_at > pg.approved_at)
          + (SELECT count(*) FROM timesheet_entries te2
              WHERE te2.header_id = pg.header_id AND te2.created_at > pg.approved_at
                AND NOT COALESCE(te2.is_system_generated, false))
          ) END AS changes_since_approval
      ) x ON true
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.timesheet_report_compliance(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.timesheet_report_compliance(jsonb) TO authenticated;

COMMENT ON FUNCTION public.timesheet_report_compliance(jsonb) IS
  'Mig 746: two-phase. Skeleton is scoped, filtered and paginated first; '
  'days_with_entries and changes_since_approval are computed only for the page. '
  'Starts from employees so somebody who logged nothing still appears.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — utilisation moves to the same semi-join
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place rather than rewritten from the file. Five small, asserted
-- substitutions leave the rest of 744's function exactly as it was verified,
-- which is worth more than the tidiness of a fresh CREATE.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;


  a1 text := '  v_scope     uuid[];';
  b1 text := '  v_mode      text;';

  a2 text := '  v_scope := time_report_scope();';
  b2 text := '  v_mode := time_report_scope_mode();';

  a3 text := '  -- Empty array from time_report_scope() means the caller may see nobody.' || E'\n' ||
             '  IF v_scope IS NOT NULL AND cardinality(v_scope) = 0 THEN';
  b3 text := '  -- ''none'' means the caller may see nobody -- distinct from ''all'', which the' || E'\n' ||
             '  -- previous uuid[] shape encoded as NULL and was one typo from inverting.' || E'\n' ||
             '  IF v_mode = ''none'' THEN';

  a4 text := '  WITH hdr AS (';
  b4 text := '  WITH scope AS MATERIALIZED (' || E'\n' ||
             '    SELECT s.employee_id FROM time_report_scope_ids() s' || E'\n' ||
             '  ),' || E'\n' ||
             '  hdr AS (';

  a5 text := '      AND  (v_scope  IS NULL OR h.employee_id   = ANY(v_scope))';
  b5 text := '      AND  (v_mode = ''all'' OR h.employee_id IN (SELECT employee_id FROM scope))';

  a6 text := '    ''scope'', jsonb_build_object(''mode'', CASE WHEN v_scope IS NULL THEN ''all'' ELSE ''scoped'' END,' || E'\n' ||
             '                                ''employee_count'', CASE WHEN v_scope IS NULL THEN NULL ELSE cardinality(v_scope) END),';
  b6 text := '    ''scope'', jsonb_build_object(''mode'', v_mode,' || E'\n' ||
             '                                ''employee_count'', CASE WHEN v_mode = ''scoped''' || E'\n' ||
             '                                                        THEN (SELECT count(*) FROM scope) ELSE NULL END),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 746: timesheet_report_utilisation not found. Migration 744 must run first.';
  END IF;

  IF position('time_report_scope_mode' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 746: timesheet_report_utilisation already uses the scope predicate. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  -- Each substitution, asserted. A silent zero-hit replace is how a function
  -- ends up half-migrated and passing.
  v_hits := (length(v_new) - length(replace(v_new, a1, ''))) / length(a1);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: v_scope declaration hits = %', v_hits; END IF;
  v_new := replace(v_new, a1, b1);

  v_hits := (length(v_new) - length(replace(v_new, a2, ''))) / length(a2);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: scope assignment hits = %', v_hits; END IF;
  v_new := replace(v_new, a2, b2);

  v_hits := (length(v_new) - length(replace(v_new, a3, ''))) / length(a3);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: empty-scope guard hits = %', v_hits; END IF;
  v_new := replace(v_new, a3, b3);

  v_hits := (length(v_new) - length(replace(v_new, a4, ''))) / length(a4);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: WITH hdr hits = %', v_hits; END IF;
  v_new := replace(v_new, a4, b4);

  v_hits := (length(v_new) - length(replace(v_new, a5, ''))) / length(a5);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: scope predicate hits = %', v_hits; END IF;
  v_new := replace(v_new, a5, b5);

  v_hits := (length(v_new) - length(replace(v_new, a6, ''))) / length(a6);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 746: scope envelope hits = %', v_hits; END IF;
  v_new := replace(v_new, a6, b6);

  IF position('v_scope' IN v_new) > 0 THEN
    RAISE EXCEPTION 'MIG 746: a v_scope reference survived the rewrite.';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'MIG 746: timesheet_report_utilisation now scopes by semi-join.';
END $mig$;

-- The array-returning original goes, so nothing can reach for the old shape.
-- Dropping rather than leaving it deprecated: a function that still works is a
-- function somebody will call, and its NULL-means-everything contract is the
-- specific mistake this migration exists to remove.
DROP FUNCTION IF EXISTS public.time_report_scope();


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4b — JIT off on the report functions
-- ═══════════════════════════════════════════════════════════════════════════
-- MEASURED, not guessed. At 10,004 employees over one month the call took
-- 1,607ms, of which JIT compilation was 1,570ms: Postgres compiled 104
-- functions to speed up roughly 24ms of actual execution. With jit off the same
-- call is 355ms.
--
-- The cause is estimate inflation, not a bad query. `generate_series` and any
-- set-returning function default to an estimated 1,000 rows, so the planner
-- prices the period CROSS JOIN at millions of rows and the total cost lands far
-- above jit_above_cost (100,000). The plan it picks is fine -- the estimate is
-- only wrong about how much work it will be, and JIT is the thing that reads
-- that estimate literally.
--
-- Report queries are short-lived and run once per screen. JIT never pays for
-- them. Setting it per-function rather than globally leaves the rest of the
-- database alone.
--
-- IF A LATER MIGRATION REPLACES EITHER FUNCTION, IT MUST KEEP THIS. PART 5
-- asserts it, so dropping it fails the deploy rather than quietly costing a
-- second and a half per report.

ALTER FUNCTION public.timesheet_report_compliance(jsonb)  SET jit = 'off';
ALTER FUNCTION public.timesheet_report_utilisation(jsonb) SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
  r         record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'time_report_scope') THEN
    v_missing := v_missing || 'the array-returning time_report_scope() survived'::text; END IF;

  FOR r IN SELECT unnest(ARRAY['time_report_scope_mode','time_report_scope_ids']) AS fn LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.proname = r.fn AND p.prosecdef) THEN
      v_missing := v_missing || (r.fn || ' is missing or not SECURITY DEFINER')::text; END IF;
  END LOOP;

  FOR r IN SELECT unnest(ARRAY['timesheet_report_compliance','timesheet_report_utilisation']) AS fn LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = r.fn;

    IF position('time_report_scope_mode' IN v_src) = 0 THEN
      v_missing := v_missing || (r.fn || ' does not use the scope predicate')::text; END IF;
    IF position('= ANY(v_scope)' IN v_src) > 0 THEN
      v_missing := v_missing || (r.fn || ' still compares against a scope array')::text; END IF;

    -- REGRESSION: mig 745 gave each report its own permission. A rewrite that
    -- restored the retired umbrella would be silently over-permissive.
    IF position('''timesheet_reports'', ''view''' IN v_src) > 0 THEN
      v_missing := v_missing || (r.fn || ' checks the retired umbrella permission')::text; END IF;
  END LOOP;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_compliance';

  -- The point of the rewrite: the expensive columns must sit behind LATERAL on
  -- the paginated set, not in the row-building projection.
  IF position('LEFT JOIN LATERAL' IN v_src) = 0 THEN
    v_missing := v_missing || 'compliance no longer computes its expensive columns per page'::text; END IF;
  IF position('changes_since_approval' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: changes_since_approval was dropped'::text; END IF;
  IF position('is_system_generated' IN v_src) = 0 THEN
    v_missing := v_missing || 'test C15: system rows are counted as post-approval changes again'::text; END IF;
  IF position('em.employed' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: leavers are being reported as late again'::text; END IF;

  -- PART 4b: measured at 1.25s per call when this is missing.
  FOR r IN SELECT unnest(ARRAY['timesheet_report_compliance','timesheet_report_utilisation']) AS fn LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = r.fn
        AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
    ) THEN
      v_missing := v_missing || (r.fn || ' lost SET jit = off -- 1.25s of JIT per call')::text; END IF;
  END LOOP;

  FOR r IN SELECT unnest(ARRAY['idx_tsh_period_employee','idx_tsh_period_status',
                               'idx_tse_header_date','idx_tse_project_date',
                               'idx_tea_header_created']) AS ix LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = r.ix) THEN
      v_missing := v_missing || ('index ' || r.ix || ' is missing')::text; END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 746 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 746 verified: scope is a semi-join, compliance paginates before it computes.';
END $mig$;

COMMIT;
