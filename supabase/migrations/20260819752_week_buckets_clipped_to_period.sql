-- =============================================================================
-- Migration : 20260819752_week_buckets_clipped_to_period.sql
-- Purpose   : Make the Utilisation "By week" chart describe the period it
--             claims to cover -- every week in it, labelled with the days it
--             actually holds.
--
-- TWO WAYS THE CHART LIED, BOTH IN THE BUCKETS RATHER THAN THE HOURS
--
--   1. THE EDGES WERE MISLABELLED.  `hdr` bounds every entry to the reported
--      months, so a bucket has only ever held in-period hours. But mig 750
--      labelled each one with the raw date_trunc('week', entry_date), which for
--      July 2026 yields a first bucket called "w/c 29-Jun" holding 1-5 Jul and
--      a last one called "w/c 27-Jul" holding 27-31 Jul. Both read as full
--      weeks, so a reader comparing bar heights sees recording collapse at both
--      ends of every month -- an artefact of the label, in a chart nothing on
--      screen contradicts.
--
--   2. EMPTY WEEKS WERE ABSENT, NOT ZERO.  GROUP BY only emits weeks that have
--      rows, so a week in which nobody recorded anything simply vanished and
--      the neighbouring weeks closed the gap. A missing bar reads as "no data
--      collected here"; a zero bar reads as "nothing was recorded here". For a
--      timesheet report those are opposite findings, and the second one is the
--      one worth acting on. This is the same argument the StackedBars comment
--      makes about vanishing pie slices.
--
-- WHAT CHANGES
--   bd_week becomes a SPINE of every week in the reported range, LEFT JOINed to
--   what was recorded, with the bucket bounds clipped to the range:
--
--     week_start  clamped up   to the first day of the range
--     week_end    clamped down to the last day of the range          (NEW)
--     partial     derived by the client as (week_end - week_start) < 6, sent
--                 explicitly so a short bar is read as a short week rather than
--                 as a drop in recording
--
--   The entry date is clamped into the range before truncation. Inside the
--   range that clamp is a no-op; outside it -- a legacy entry dated beyond its
--   header's month -- it puts those hours in an edge bucket instead of letting
--   them fall out of the chart. The chart must still sum to
--   totals.recorded_minutes, and a spine join alone would quietly break that.
--
-- WHAT DOES NOT CHANGE
--   No hours move between weeks that exist. `week_start` is still present and
--   still the first key, so a frontend that has not deployed yet keeps
--   rendering exactly as it does today.
--
-- Depends on : 744 (the RPC), 745 (permission), 746 (scope), 750 (breakdowns)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  -- Anchored on the function as mig 750 left it, read from pg_get_functiondef
  -- rather than reconstructed from the migration file.
  a_wk CONSTANT text :=
'  bd_week AS (' || E'\n' ||
'    SELECT date_trunc(''week'', en.entry_date)::date AS week_start,' || E'\n' ||
'           COALESCE(sum(en.hours_minutes) FILTER (' || E'\n' ||
'             WHERE COALESCE(tt2.category, ''attendance'') = ''attendance''), 0)::bigint AS attendance_minutes,' || E'\n' ||
'           COALESCE(sum(en.hours_minutes) FILTER (' || E'\n' ||
'             WHERE tt2.category = ''absence''), 0)::bigint AS absence_minutes' || E'\n' ||
'    FROM   ent en' || E'\n' ||
'    LEFT   JOIN time_types tt2 ON tt2.id = en.time_type_id' || E'\n' ||
'    GROUP  BY 1' || E'\n' ||
'    ORDER  BY 1' || E'\n' ||
'  )';

  b_wk CONSTANT text :=
'  bd_week AS (' || E'\n' ||
'    -- A spine of every week in the reported range, LEFT JOINed to what was' || E'\n' ||
'    -- recorded, so a week nobody logged in is a zero bar rather than a gap.' || E'\n' ||
'    -- Bounds are clipped to the range: the first and last buckets state the' || E'\n' ||
'    -- days they hold instead of naming a Monday in the adjacent month.' || E'\n' ||
'    SELECT GREATEST(sp.wk, v_from)                                     AS week_start,' || E'\n' ||
'           LEAST(sp.wk + 6, (v_to + interval ''1 month'')::date - 1)     AS week_end,' || E'\n' ||
'           COALESCE(s.attendance_minutes, 0)::bigint                   AS attendance_minutes,' || E'\n' ||
'           COALESCE(s.absence_minutes, 0)::bigint                      AS absence_minutes' || E'\n' ||
'    FROM   (SELECT generate_series(' || E'\n' ||
'                     date_trunc(''week'', v_from),' || E'\n' ||
'                     date_trunc(''week'', (v_to + interval ''1 month'')::date - 1),' || E'\n' ||
'                     interval ''1 week'')::date AS wk) sp' || E'\n' ||
'    LEFT   JOIN (' || E'\n' ||
'      -- The entry date is clamped into the range before truncation. Inside' || E'\n' ||
'      -- the range that is a no-op; outside it, an entry dated beyond its' || E'\n' ||
'      -- header month lands in an edge bucket instead of falling out of the' || E'\n' ||
'      -- chart, which would stop the bars summing to recorded_minutes.' || E'\n' ||
'      SELECT date_trunc(''week'', GREATEST(LEAST(en.entry_date,' || E'\n' ||
'               (v_to + interval ''1 month'')::date - 1), v_from))::date AS wk,' || E'\n' ||
'             COALESCE(sum(en.hours_minutes) FILTER (' || E'\n' ||
'               WHERE COALESCE(tt2.category, ''attendance'') = ''attendance''), 0)::bigint AS attendance_minutes,' || E'\n' ||
'             COALESCE(sum(en.hours_minutes) FILTER (' || E'\n' ||
'               WHERE tt2.category = ''absence''), 0)::bigint AS absence_minutes' || E'\n' ||
'      FROM   ent en' || E'\n' ||
'      LEFT   JOIN time_types tt2 ON tt2.id = en.time_type_id' || E'\n' ||
'      GROUP  BY 1' || E'\n' ||
'    ) s ON s.wk = sp.wk' || E'\n' ||
'    ORDER  BY 1' || E'\n' ||
'  )';

  a_env CONSTANT text :=
'                 ''week_start'', w.week_start,' || E'\n';

  b_env CONSTANT text :=
'                 ''week_start'', w.week_start,' || E'\n' ||
'                 ''week_end'',   w.week_end,' || E'\n' ||
'                 ''partial'',    (w.week_end - w.week_start) < 6,' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 752: timesheet_report_utilisation not found. 744 must run first.';
  END IF;

  IF position('bd_week' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 752: the weekly breakdown is absent. 750 must run first.';
  END IF;

  IF position('''week_end''' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 752: week buckets already clipped. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a_wk, ''))) / length(a_wk);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 752: bd_week CTE matched % times, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_wk, b_wk);

  v_hits := (length(v_new) - length(replace(v_new, a_env, ''))) / length(a_env);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 752: by_week envelope matched % times, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_env, b_env);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 752: by_week now spans every week in the range, with clipped bounds.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF position('''week_end'',   w.week_end' IN v_src) = 0 THEN
    v_missing := v_missing || 'the clipped upper bound is missing from the envelope'::text; END IF;
  IF position('''partial''' IN v_src) = 0 THEN
    v_missing := v_missing || 'the partial flag is missing -- a short bar would read as a drop in recording'::text; END IF;
  IF position('generate_series(' IN v_src) = 0 THEN
    v_missing := v_missing || 'the week spine is missing -- empty weeks would vanish instead of reading zero'::text; END IF;

  -- REGRESSIONS: everything 744-750 established must survive.
  IF position('bd_project' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 750: the project breakdown was dropped'::text; END IF;
  IF position('other_minutes' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 750: the project tail remainder was dropped'::text; END IF;
  IF position('time_report_scope_mode' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 746: the scope predicate was dropped'::text; END IF;
  IF position('''timesheet_reports'', ''view_utilisation''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 745: the per-report permission gate was dropped'::text; END IF;
  IF position('FROM timesheet_entry_activities a' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: nested activities were dropped'::text; END IF;
  IF position('sum(planned_minutes), 0) FROM hdr' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: planned_minutes must come from the headers, not the rows'::text; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation'
      AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
  ) THEN
    v_missing := v_missing || 'mig 746: SET jit = off was lost'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 752 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 752 verified: every week in the range is present and states the days it holds.';
END $mig$;

COMMIT;
