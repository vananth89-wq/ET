-- =============================================================================
-- Migration : 20260818747_compliance_summary_is_population.sql
-- Purpose   : The KPI tiles must describe the POPULATION, not the filtered rows.
--
-- THE BUG, AND IT IS A DESIGN ERROR NOT A TYPO
--   Migration 746 computed `summary` over the same set as `rows` -- correct for
--   a footer total, and wrong the moment the tiles became the filter control.
--
--   Click "Not started" and the RPC applies states = ['not_started']. The
--   summary is then computed over those rows, so every other tile reads 0:
--
--       before        10 expected · 4 not started · 5 to be submitted · 1 approved
--       after click    4 expected · 4 not started · 0 to be submitted · 0 approved
--
--   The tiles are now navigation you have destroyed by using it. There is no
--   "To be submitted" left to click, so the only way back is Reset or a page
--   refresh -- which is exactly what happened on Dev.
--
-- THE RULE
--   A KPI tile has two jobs and they want opposite things. As a SUMMARY it
--   should describe what you are looking at. As NAVIGATION it must describe
--   where you can go. When the tile is the control, navigation wins: the counts
--   are of the population, and the row count beside Export is what reflects the
--   filter.
--
--   So `summary` is computed AFTER period, scope, employee and department --
--   filters the tiles do not own, and should therefore respect -- but BEFORE
--   state and overdue, which are the filters the tiles themselves apply.
--
-- Depends on : 746
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  -- 1. the state filter leaves `filtered`, which becomes the population
  a1 text :=
'    FROM   core c' || E'\n' ||
'    WHERE  (v_states IS NULL OR c.state = ANY(v_states))' || E'\n' ||
'  ),';
  b1 text :=
'    FROM   core c' || E'\n' ||
'  ),';

  -- 2. ...and lands on `final`, alongside the overdue filter
  a2 text := '    SELECT * FROM filtered f WHERE (NOT v_overdue OR f.is_overdue)';
  b2 text :=
'    SELECT * FROM filtered f' || E'\n' ||
'     WHERE (v_states IS NULL OR f.state = ANY(v_states))' || E'\n' ||
'       AND (NOT v_overdue OR f.is_overdue)';

  -- 3. the aggregate reads the population, and stops claiming to be total_rows
  a3 text :=
'    SELECT count(*)                                                   AS total_rows,';
  b3 text :=
'    SELECT count(*)                                                   AS population,';

  a4 text :=
'    FROM   final' || E'\n' ||
'  ),' || E'\n' ||
'  -- Phase 2 starts here: only these rows pay for the expensive columns.';
  b4 text :=
'    FROM   filtered' || E'\n' ||
'  ),' || E'\n' ||
'  -- Phase 2 starts here: only these rows pay for the expensive columns.';

  -- 4. total_rows is what the table is showing, so it comes from `final`
  a5 text := '    ''total_rows'', (SELECT total_rows FROM agg),';
  b5 text := '    ''total_rows'', (SELECT count(*) FROM final),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_compliance';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 747: timesheet_report_compliance not found. 746 must run first.';
  END IF;

  IF position('AS population,' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 747: the summary already describes the population. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a1, ''))) / length(a1);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 747: filtered state-filter hits = %', v_hits; END IF;
  v_new := replace(v_new, a1, b1);

  v_hits := (length(v_new) - length(replace(v_new, a2, ''))) / length(a2);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 747: final predicate hits = %', v_hits; END IF;
  v_new := replace(v_new, a2, b2);

  v_hits := (length(v_new) - length(replace(v_new, a3, ''))) / length(a3);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 747: agg total_rows column hits = %', v_hits; END IF;
  v_new := replace(v_new, a3, b3);

  v_hits := (length(v_new) - length(replace(v_new, a4, ''))) / length(a4);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 747: agg source hits = %', v_hits; END IF;
  v_new := replace(v_new, a4, b4);

  v_hits := (length(v_new) - length(replace(v_new, a5, ''))) / length(a5);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 747: total_rows envelope hits = %', v_hits; END IF;
  v_new := replace(v_new, a5, b5);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 747: compliance summary now counts the population; total_rows counts the page set.';
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
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_compliance';

  IF position('AS population,' IN v_src) = 0 THEN
    v_missing := v_missing || 'the aggregate does not count the population'::text; END IF;
  IF position('''total_rows'', (SELECT count(*) FROM final)' IN v_src) = 0 THEN
    v_missing := v_missing || 'total_rows no longer counts the filtered set'::text; END IF;
  IF position('FROM   filtered' IN v_src) = 0 THEN
    v_missing := v_missing || 'agg is not reading the pre-state-filter set'::text; END IF;

  -- REGRESSIONS: everything 744/746 established must survive this rewrite.
  IF position('LEFT JOIN LATERAL' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 746: expensive columns are no longer per-page'::text; END IF;
  IF position('time_report_scope_mode' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 746: the scope predicate was dropped'::text; END IF;
  IF position('em.employed' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: leavers are being reported as late again'::text; END IF;
  IF position('is_system_generated' IN v_src) = 0 THEN
    v_missing := v_missing || 'test C15: system rows counted as post-approval changes again'::text; END IF;
  IF position('''timesheet_reports'', ''view_compliance''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 745: the per-report permission gate was dropped'::text; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_compliance'
      AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
  ) THEN
    v_missing := v_missing || 'mig 746: SET jit = off was lost -- 1.25s per call'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 747 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 747 verified: tiles describe the population, rows describe the filter.';
END $mig$;

COMMIT;
