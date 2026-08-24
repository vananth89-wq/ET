-- =============================================================================
-- Migration : 20260820771_utilisation_sees_managed_projects.sql
-- Purpose   : The second and last reader of the 767 predicate. A project
--             manager sees the INDIVIDUAL ENTRIES against projects they manage,
--             including entries by employees outside their target population --
--             with the HR columns on those rows redacted, visibly.
--
-- WHY THIS IS THE RISKY HALF, AND WHAT IS DONE ABOUT IT
--   770 widened a report grained on the PROJECT, where the only employee-derived
--   figure was a count. This widens a report grained on the ENTRY: rows about
--   named individuals become visible to someone with no HR relationship to them.
--   Three things follow, and all three are enforced here rather than in the UI.
--
--   1. DEPARTMENT IS NULLED on rows visible only via the project. Design doc s5
--      option (a): the PM needs to know hours went to their project; they do not
--      need the contributor's place in the org. The name stays -- a report of
--      hours with the person blanked out answers nothing.
--
--   2. THE DEPARTMENT FILTER SUPPRESSES THE PM BRANCH ENTIRELY. Applying it to
--      PM rows would let a manager binary-search a redacted employee's
--      department by toggling the filter and watching rows appear -- redaction
--      that a filter can undo is not redaction. When a department filter is
--      active the report reverts to employee scope alone and says so.
--
--   3. planned_minutes IS FLAGGED INCOMPLETE. It comes from `hdr`, which is
--      still employee-scoped, so with PM rows present the recorded total counts
--      hours the planned total has no capacity for. That is exactly the
--      incoherent denominator of s8.1b, arriving by a different door. The
--      envelope carries planned_covers_all_rows so the screen suppresses the
--      Planned tile and the rate, using the mechanism already built for
--      project filters.
--
-- SAME DISJOINT UNION AS 770  hdr_pm excludes every employee hdr admits, so the
--   branches cannot overlap, nothing is deduped, and no entry is counted twice.
--   Guarded by v_pm, a non-manager's branch is a constant false and Postgres
--   skips it whole -- which is what preserves the 15ms scoped plan 746 measured.
--
-- PATCHED IN PLACE, not re-issued. 745, 746, 750 and 752 have each amended this
--   function; a CREATE OR REPLACE built from an older file would silently revert
--   whichever of them the author had not read. That is the defect behind 734,
--   736 and 737. Every anchor below is asserted to match exactly once.
--
-- Depends on : 744, 745, 746, 750, 752 (this function), 767 (the predicate)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  a_decl CONSTANT text := '  v_mode      text;' || E'\n';
  b_decl CONSTANT text := '  v_mode      text;' || E'\n' ||
                          '  v_pm        boolean;' || E'\n';

  a_set  CONSTANT text := '  v_mode := time_report_scope_mode();' || E'\n';
  b_set  CONSTANT text := '  v_mode := time_report_scope_mode();' || E'\n' ||
                          '  -- 767. False for everyone without the grant, which keeps the PM branch' || E'\n' ||
                          '  -- out of the plan entirely for almost every run.' || E'\n' ||
                          '  v_pm   := time_report_is_project_manager();' || E'\n';

  -- A project manager with no employee population is a real configuration, and
  -- exactly who this feature exists for.
  a_none CONSTANT text := '  IF v_mode = ''none'' THEN' || E'\n';
  b_none CONSTANT text := '  IF v_mode = ''none'' AND NOT v_pm THEN' || E'\n';

  a_hdr CONSTANT text :=
'  hdr AS (' || E'\n' ||
'    SELECT h.*' || E'\n' ||
'    FROM   timesheet_headers h' || E'\n' ||
'    WHERE  h.period BETWEEN v_from AND v_to' || E'\n' ||
'      AND  (v_mode = ''all'' OR h.employee_id IN (SELECT employee_id FROM scope))' || E'\n' ||
'      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))' || E'\n' ||
'      AND  (v_dept   IS NULL OR h.department_id = ANY(v_dept))' || E'\n' ||
'      AND  (v_status IS NULL OR h.status        = ANY(v_status))' || E'\n' ||
'  ),' || E'\n';

  b_hdr CONSTANT text :=
'  mgd AS MATERIALIZED (' || E'\n' ||
'    SELECT m.project_id FROM time_report_managed_project_ids() m' || E'\n' ||
'  ),' || E'\n' ||
'  hdr AS (' || E'\n' ||
'    SELECT h.*' || E'\n' ||
'    FROM   timesheet_headers h' || E'\n' ||
'    WHERE  h.period BETWEEN v_from AND v_to' || E'\n' ||
'      AND  (v_mode = ''all'' OR h.employee_id IN (SELECT employee_id FROM scope))' || E'\n' ||
'      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))' || E'\n' ||
'      AND  (v_dept   IS NULL OR h.department_id = ANY(v_dept))' || E'\n' ||
'      AND  (v_status IS NULL OR h.status        = ANY(v_status))' || E'\n' ||
'  ),' || E'\n' ||
'  -- Headers of employees the caller CANNOT see, kept only so their entries on' || E'\n' ||
'  -- managed projects can surface. Disjoint from hdr by construction.' || E'\n' ||
'  --' || E'\n' ||
'  -- v_dept IS NULL is a SECURITY condition, not a convenience: department is' || E'\n' ||
'  -- redacted on these rows, and a filter that makes redacted rows appear and' || E'\n' ||
'  -- disappear would let a manager binary-search the value back out.' || E'\n' ||
'  hdr_pm AS (' || E'\n' ||
'    SELECT h.*' || E'\n' ||
'    FROM   timesheet_headers h' || E'\n' ||
'    WHERE  v_pm' || E'\n' ||
'      AND  v_dept IS NULL' || E'\n' ||
'      AND  h.period BETWEEN v_from AND v_to' || E'\n' ||
'      AND  NOT (v_mode = ''all'' OR h.employee_id IN (SELECT employee_id FROM scope))' || E'\n' ||
'      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))' || E'\n' ||
'      AND  (v_status IS NULL OR h.status        = ANY(v_status))' || E'\n' ||
'  ),' || E'\n';

  a_ent CONSTANT text :=
'           h.id AS header_id, h.employee_id, h.period, h.status AS header_status,' || E'\n' ||
'           h.department_id, h.department_name' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    JOIN   hdr h ON h.id = e.header_id' || E'\n' ||
'    LEFT   JOIN time_types tt ON tt.id = e.time_type_id' || E'\n' ||
'    WHERE  (v_proj IS NULL OR e.project_id   = ANY(v_proj))' || E'\n' ||
'      AND  (v_tt   IS NULL OR e.time_type_id = ANY(v_tt))' || E'\n' ||
'      AND  (v_cat  IS NULL OR tt.category    = ANY(v_cat))' || E'\n' ||
'      AND  (v_sys  OR NOT e.is_system_generated)' || E'\n' ||
'  ),' || E'\n';

  b_ent CONSTANT text :=
'           h.id AS header_id, h.employee_id, h.period, h.status AS header_status,' || E'\n' ||
'           h.department_id, h.department_name,' || E'\n' ||
'           false AS via_project' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    JOIN   hdr h ON h.id = e.header_id' || E'\n' ||
'    LEFT   JOIN time_types tt ON tt.id = e.time_type_id' || E'\n' ||
'    WHERE  (v_proj IS NULL OR e.project_id   = ANY(v_proj))' || E'\n' ||
'      AND  (v_tt   IS NULL OR e.time_type_id = ANY(v_tt))' || E'\n' ||
'      AND  (v_cat  IS NULL OR tt.category    = ANY(v_cat))' || E'\n' ||
'      AND  (v_sys  OR NOT e.is_system_generated)' || E'\n' ||
'    UNION ALL' || E'\n' ||
'    -- Entries on projects this caller MANAGES, by people they cannot' || E'\n' ||
'    -- otherwise see. via_project drives the redaction below.' || E'\n' ||
'    SELECT e.id, e.entry_date, e.entry_kind, e.hours_minutes, e.notes,' || E'\n' ||
'           e.project_id, e.time_type_id, e.is_system_generated,' || E'\n' ||
'           e.created_at, e.updated_at,' || E'\n' ||
'           h.id AS header_id, h.employee_id, h.period, h.status AS header_status,' || E'\n' ||
'           h.department_id, h.department_name,' || E'\n' ||
'           true AS via_project' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    JOIN   hdr_pm h ON h.id = e.header_id' || E'\n' ||
'    LEFT   JOIN time_types tt ON tt.id = e.time_type_id' || E'\n' ||
'    WHERE  e.project_id IN (SELECT project_id FROM mgd)' || E'\n' ||
'      AND  (v_proj IS NULL OR e.project_id   = ANY(v_proj))' || E'\n' ||
'      AND  (v_tt   IS NULL OR e.time_type_id = ANY(v_tt))' || E'\n' ||
'      AND  (v_cat  IS NULL OR tt.category    = ANY(v_cat))' || E'\n' ||
'      AND  (v_sys  OR NOT e.is_system_generated)' || E'\n' ||
'  ),' || E'\n';

  -- planned_minutes still comes from hdr, which is still employee-scoped. Say
  -- so, rather than let a rate be computed across two different populations.
  a_tot CONSTANT text :=
'      ''project_count'',    (SELECT count(DISTINCT project_id) FROM ent WHERE project_id IS NOT NULL)' || E'\n' ||
'    ),' || E'\n';
  b_tot CONSTANT text :=
'      ''project_count'',    (SELECT count(DISTINCT project_id) FROM ent WHERE project_id IS NOT NULL),' || E'\n' ||
'      ''planned_covers_all_rows'', NOT EXISTS (SELECT 1 FROM ent WHERE via_project)' || E'\n' ||
'    ),' || E'\n';

  a_env CONSTANT text := '    ''scope'', jsonb_build_object(''mode'', v_mode,' || E'\n';
  b_env CONSTANT text :=
'    ''pm'', jsonb_build_object(' || E'\n' ||
'      ''is_manager'',             v_pm,' || E'\n' ||
'      ''managed_projects'',       (SELECT count(*) FROM mgd),' || E'\n' ||
'      ''via_project_rows'',       (SELECT count(*) FROM ent WHERE via_project),' || E'\n' ||
'      ''redacted_columns'',       CASE WHEN EXISTS (SELECT 1 FROM ent WHERE via_project)' || E'\n' ||
'                                      THEN jsonb_build_array(''department_name'') ELSE ''[]''::jsonb END,' || E'\n' ||
'      ''dept_filter_suppressed'', (v_pm AND v_dept IS NOT NULL)),' || E'\n' ||
'' || E'\n' ||
'    ''scope'', jsonb_build_object(''mode'', v_mode,' || E'\n';

  a_row CONSTANT text := '                 ''department_name'', x.department_name,' || E'\n';
  b_row CONSTANT text :=
'                 -- Redacted on rows the caller reaches only through the' || E'\n' ||
'                 -- project. The NAME stays: a report of hours with the person' || E'\n' ||
'                 -- blanked out answers nothing.' || E'\n' ||
'                 ''department_name'', CASE WHEN x.via_project THEN NULL' || E'\n' ||
'                                          ELSE x.department_name END,' || E'\n' ||
'                 ''via_project'',     x.via_project,' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 771: timesheet_report_utilisation not found. 744 must run first.';
  END IF;
  IF position('bd_week' IN v_src) = 0 OR position('week_end' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 771: 750 and 752 must run first -- anchors are taken from the function they leave.';
  END IF;
  IF position('time_report_managed_project_ids' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 771: utilisation already reads the PM predicate. Nothing to do.';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, a_decl, ''))) / length(a_decl);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: DECLARE anchor matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_decl, b_decl);

  v_hits := (length(v_new) - length(replace(v_new, a_set, ''))) / length(a_set);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: scope-mode assignment matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_set, b_set);

  v_hits := (length(v_new) - length(replace(v_new, a_none, ''))) / length(a_none);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: scope-none guard matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_none, b_none);

  v_hits := (length(v_new) - length(replace(v_new, a_hdr, ''))) / length(a_hdr);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: hdr CTE matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_hdr, b_hdr);

  v_hits := (length(v_new) - length(replace(v_new, a_ent, ''))) / length(a_ent);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: ent CTE matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_ent, b_ent);

  v_hits := (length(v_new) - length(replace(v_new, a_tot, ''))) / length(a_tot);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: totals block matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_tot, b_tot);

  v_hits := (length(v_new) - length(replace(v_new, a_env, ''))) / length(a_env);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: scope envelope matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_env, b_env);

  v_hits := (length(v_new) - length(replace(v_new, a_row, ''))) / length(a_row);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'MIG 771: department_name row key matched %, expected 1', v_hits; END IF;
  v_new := replace(v_new, a_row, b_row);

  EXECUTE v_new;
  RAISE NOTICE 'MIG 771: utilisation now shows managed-project entries, with department redacted.';
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

  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    v_missing := v_missing || 'the report does not read the PM predicate'::text; END IF;
  IF position('UNION ALL' IN v_src) = 0 THEN
    v_missing := v_missing || 'the PM branch was folded into the scope predicate, defeating the semi-join prune 746 measured'::text; END IF;
  IF position('CASE WHEN x.via_project THEN NULL' IN v_src) = 0 THEN
    v_missing := v_missing || 'department is NOT redacted on project-only rows'::text; END IF;
  IF position('AND  v_dept IS NULL' IN v_src) = 0 THEN
    v_missing := v_missing || 'the department filter does not suppress the PM branch -- redaction a filter can undo is not redaction'::text; END IF;
  IF position('planned_covers_all_rows' IN v_src) = 0 THEN
    v_missing := v_missing || 'planned_minutes is not flagged incomplete when PM rows are present'::text; END IF;
  IF position('''via_project'',     x.via_project' IN v_src) = 0 THEN
    v_missing := v_missing || 'rows do not say how they became visible'::text; END IF;

  -- Everything 744-752 established must survive.
  IF position('''timesheet_reports'', ''view_utilisation''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 745: the per-report permission gate was dropped'::text; END IF;
  IF position('time_report_scope_mode' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 746: the scope predicate was dropped'::text; END IF;
  IF position('FROM timesheet_entry_activities a' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: nested activities were dropped'::text; END IF;
  IF position('sum(planned_minutes), 0) FROM hdr' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 744: planned_minutes must come from the headers'::text; END IF;
  IF position('bd_project' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 750: the project breakdown was dropped'::text; END IF;
  IF position('week_end' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 752: the clipped week bounds were dropped'::text; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation'
      AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
  ) THEN
    v_missing := v_missing || 'mig 746: SET jit = off was lost'::text; END IF;

  -- Compliance has no project dimension and must never have been touched.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_compliance'
      AND pg_get_functiondef(p.oid) LIKE '%time_report_managed_project_ids%'
  ) THEN
    v_missing := v_missing || 'compliance was widened -- it is grained on the employee-month and has no project dimension'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 771 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 771 verified: managed-project entries are visible, department redacted, planned flagged.';
END $mig$;

COMMIT;
