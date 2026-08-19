-- =============================================================================
-- Migration : 20260819750_utilisation_breakdowns.sql
-- Purpose   : Whole-set breakdowns for the Utilisation report, so it can carry
--             charts that describe the REPORT rather than the visible page.
--
-- WHY THIS MIGRATION EXISTS BEFORE THE CHARTS DO
--   The utilisation screen has shipped without charts on purpose. The RPC
--   paginates, so anything drawn from `rows` would describe fifty entries while
--   looking like it describes the whole filtered set — a chart that is wrong in
--   a way nothing on screen contradicts. The KPI strip was safe only because
--   `totals` is already computed over everything.
--
--   So the breakdowns are computed here, over `ent` — the same set the totals
--   use, after every filter and after scope.
--
-- WHAT IS AND IS NOT INCLUDED
--   by_project  hours per project, ordered, with the tail folded into a single
--               `other_minutes` remainder rather than truncated silently.
--   by_week     hours per ISO week, split attendance / absence.
--
--   NOT billable vs internal: `projects` still has no project_type column. That
--   is the next schema migration and the chart the PMO actually wants; adding a
--   fake split now would be worse than not having it.
--
--   NOT top activities: activities are free text (mig 717) and unique on the
--   name EXACTLY, so "Testing" and "testing" are two rows and "Dev" /
--   "Development" / "Coding" are three. A percentage over that is precise-
--   looking and wrong. It needs normalisation, and a decision about a catalogue,
--   before it can be charted.
--
-- Depends on : 744 (the RPC), 745 (its permission), 746 (its scope predicate)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  -- Anchored on the function as it stands after 746, read from
  -- pg_get_functiondef rather than reconstructed from any one migration file.
  a_ent CONSTANT text :=
'      AND  (v_sys  OR NOT e.is_system_generated)' || E'\n' ||
'  )' || E'\n' ||
'  SELECT jsonb_build_object(';

  b_ent CONSTANT text :=
'      AND  (v_sys  OR NOT e.is_system_generated)' || E'\n' ||
'  ),' || E'\n' ||
'  -- ── Breakdowns, over the WHOLE filtered set ────────────────────────────' || E'\n' ||
'  -- Same source as `totals`. A chart fed from the page would describe fifty' || E'\n' ||
'  -- rows while looking like it describes the report.' || E'\n' ||
'  bd_project AS (' || E'\n' ||
'    SELECT COALESCE(pj.name, ''(no project)'') AS label,' || E'\n' ||
'           en.project_id                       AS project_id,' || E'\n' ||
'           sum(en.hours_minutes)::bigint       AS minutes' || E'\n' ||
'    FROM   ent en' || E'\n' ||
'    LEFT   JOIN projects pj ON pj.id = en.project_id' || E'\n' ||
'    GROUP  BY 1, 2' || E'\n' ||
'    ORDER  BY 3 DESC' || E'\n' ||
'  ),' || E'\n' ||
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
'  )' || E'\n' ||
'  SELECT jsonb_build_object(';

  -- The envelope gains one key, immediately before `scope`.
  a_env CONSTANT text := '    ''scope'', jsonb_build_object(''mode'', v_mode,';
  b_env CONSTANT text :=
'    -- Computed over every filtered row, never the page. The client folds the' || E'\n' ||
'    -- project tail into "Other" for display; the remainder is sent explicitly' || E'\n' ||
'    -- so a truncated chart can say what it left out instead of implying the' || E'\n' ||
'    -- list is complete.' || E'\n' ||
'    ''breakdowns'', jsonb_build_object(' || E'\n' ||
'      ''by_project'', COALESCE((' || E'\n' ||
'        SELECT jsonb_agg(jsonb_build_object(' || E'\n' ||
'                 ''project_id'', b.project_id, ''label'', b.label, ''minutes'', b.minutes)' || E'\n' ||
'               ORDER BY b.minutes DESC)' || E'\n' ||
'        FROM (SELECT * FROM bd_project ORDER BY minutes DESC LIMIT 12) b), ''[]''::jsonb),' || E'\n' ||
'      ''other_minutes'', COALESCE((' || E'\n' ||
'        SELECT sum(minutes) FROM (' || E'\n' ||
'          SELECT minutes FROM bd_project ORDER BY minutes DESC OFFSET 12) o), 0),' || E'\n' ||
'      ''other_projects'', COALESCE((' || E'\n' ||
'        SELECT count(*) FROM (' || E'\n' ||
'          SELECT 1 FROM bd_project ORDER BY minutes DESC OFFSET 12) o2), 0),' || E'\n' ||
'      ''by_week'', COALESCE((' || E'\n' ||
'        SELECT jsonb_agg(jsonb_build_object(' || E'\n' ||
'                 ''week_start'', w.week_start,' || E'\n' ||
'                 ''attendance_minutes'', w.attendance_minutes,' || E'\n' ||
'                 ''absence_minutes'', w.absence_minutes)' || E'\n' ||
'               ORDER BY w.week_start)' || E'\n' ||
'        FROM bd_week w), ''[]''::jsonb)' || E'\n' ||
'    ),' || E'\n' ||
'' || E'\n' ||
'    ''scope'', jsonb_build_object(''mode'', v_mode,';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 750: timesheet_report_utilisation not found. 744 must run first.';
  END IF;

  IF position('bd_project' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 750: breakdowns already present. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a_ent, ''))) / length(a_ent);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 750: ent-CTE tail matched % times, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_ent, b_ent);

  v_hits := (length(v_new) - length(replace(v_new, a_env, ''))) / length(a_env);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 750: scope envelope key matched % times, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_env, b_env);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 750: timesheet_report_utilisation now returns whole-set breakdowns.';
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

  IF position('''breakdowns'', jsonb_build_object' IN v_src) = 0 THEN
    v_missing := v_missing || 'the breakdowns envelope key is missing'::text; END IF;
  IF position('bd_week' IN v_src) = 0 THEN
    v_missing := v_missing || 'the weekly breakdown is missing'::text; END IF;
  IF position('other_minutes' IN v_src) = 0 THEN
    v_missing := v_missing || 'the project tail remainder is missing -- a truncated chart would lie'::text; END IF;

  -- REGRESSIONS: everything 744-746 established must survive.
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
    RAISE EXCEPTION E'MIG 750 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 750 verified: breakdowns cover the whole filtered set.';
END $mig$;

COMMIT;
