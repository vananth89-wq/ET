-- =============================================================================
-- Migration 810 — a project shows the help it was given, and still does not
--                 count it
--
-- 801 and 802 gave cross-project help somewhere to live: related_project_id,
-- invisible to every function that reads project_id. That was the point, and it
-- left the obvious hole -- the hours are recorded correctly and reportable, and
-- the lead of the project that received the help has nowhere to see them.
--
-- Design decision D6, in full: support hours are VISIBLE on the helped project
-- and EXCLUDED from its utilisation, burn and cost. Both halves, or the feature
-- is either dishonest or useless.
--
-- HOW THE EXCLUSION IS GUARANTEED
-- ═══════════════════════════════
-- Not by filtering. By never touching the thing that computes the numbers.
--
-- recorded_minutes, entry_count, contributor_count, months_active and
-- consumed_pct are all derived from the `ent` CTE. This migration does not add
-- a column to `ent`, does not widen its WHERE, and does not touch `agg`. It
-- adds a SEPARATE pair of CTEs keyed on related_project_id, and LEFT JOINs the
-- result alongside. So "support hours never enter the burn" is a property of
-- the query's shape, not a promise that some future editor has to remember.
--
-- The verification below asserts that `ent` still reads exactly what it read
-- before, precisely so a later edit that quietly folded support into it would
-- fail here rather than in a budget meeting.
--
-- WHY TWO CTEs AND NOT ONE
--   The rows must be UNIONed BEFORE they are aggregated, exactly as `ent` and
--   `agg` are. Aggregating inside each branch and unioning the results would
--   give two rows for a project that appears in both, and the LEFT JOIN into
--   `final` would then multiply that project's row -- one project appearing
--   twice in a report about projects.
--
-- A LIMITATION, STATED RATHER THAN DISCOVERED
--   `universe` decides which projects appear, from `agg` plus the caller's own
--   managed projects. A project with ONLY support hours and none of its own is
--   therefore absent unless the caller manages it. In practice a project that
--   attracts help has hours of its own, and a lead always sees their own
--   projects whatever the dates -- but if that ever stops being true, universe
--   is the single place it changes.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   766 and 770 have both written this function. Every anchor is asserted to
--   match exactly once and the migration aborts rather than guessing.
--
-- Depends on : 766, 770 (this function), 801 (related_project_id)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  -- ── The support CTEs, inserted ahead of agg ────────────────────────────────
  a_agg CONSTANT text :=
'  ),' || E'\n' ||
'  agg AS (' || E'\n' ||
'    SELECT en.project_id,' || E'\n';

  b_agg CONSTANT text :=
'  ),' || E'\n' ||
'  -- mig 810. Help GIVEN to a project, read from related_project_id and from' || E'\n' ||
'  -- nowhere else. Deliberately not folded into `ent`: every figure this report' || E'\n' ||
'  -- publishes about a project -- recorded_minutes, contributor_count,' || E'\n' ||
'  -- consumed_pct, the billable split -- is derived from `ent`, and leaving it' || E'\n' ||
'  -- untouched is what makes the exclusion structural instead of a rule someone' || E'\n' ||
'  -- has to keep honouring.' || E'\n' ||
'  --' || E'\n' ||
'  -- Unioned before aggregating, exactly as ent/agg are. Aggregating inside' || E'\n' ||
'  -- each branch and unioning the results would give a project two rows, and' || E'\n' ||
'  -- the LEFT JOIN below would then print it twice.' || E'\n' ||
'  sup_ent AS (' || E'\n' ||
'    SELECT e.related_project_id AS project_id, e.hours_minutes, h.employee_id' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    JOIN   hdr h ON h.id = e.header_id' || E'\n' ||
'    WHERE  e.related_project_id IS NOT NULL' || E'\n' ||
'      AND  (v_sys OR NOT e.is_system_generated)' || E'\n' ||
'    UNION ALL' || E'\n' ||
'    SELECT e.related_project_id, e.hours_minutes, h.employee_id' || E'\n' ||
'    FROM   timesheet_entries e' || E'\n' ||
'    JOIN   hdr_pm h ON h.id = e.header_id' || E'\n' ||
'    WHERE  e.related_project_id IN (SELECT project_id FROM mgd)' || E'\n' ||
'      AND  (v_sys OR NOT e.is_system_generated)' || E'\n' ||
'  ),' || E'\n' ||
'  sup AS (' || E'\n' ||
'    SELECT s.project_id,' || E'\n' ||
'           sum(s.hours_minutes)::bigint          AS support_minutes,' || E'\n' ||
'           count(DISTINCT s.employee_id)::bigint AS support_contributors' || E'\n' ||
'    FROM   sup_ent s' || E'\n' ||
'    GROUP  BY 1' || E'\n' ||
'  ),' || E'\n' ||
'  agg AS (' || E'\n' ||
'    SELECT en.project_id,' || E'\n';

  -- ── final carries the two figures ─────────────────────────────────────────
  a_fin CONSTANT text :=
'           COALESCE(a.months_active,     0) AS months_active,' || E'\n';
  b_fin CONSTANT text :=
'           COALESCE(a.months_active,     0) AS months_active,' || E'\n' ||
'           -- Alongside the project own figures, never inside them.' || E'\n' ||
'           COALESCE(s.support_minutes,      0) AS support_minutes,' || E'\n' ||
'           COALESCE(s.support_contributors, 0) AS support_contributors,' || E'\n';

  a_join CONSTANT text :=
'    LEFT   JOIN agg a  ON a.project_id = u.id' || E'\n';
  b_join CONSTANT text :=
'    LEFT   JOIN agg a  ON a.project_id = u.id' || E'\n' ||
'    LEFT   JOIN sup s  ON s.project_id = u.id' || E'\n';

  -- ── totals ────────────────────────────────────────────────────────────────
  a_tot CONSTANT text :=
'      ''unclassified_minutes'', (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref IS NULL), 0) FROM ranked),' || E'\n';
  b_tot CONSTANT text :=
'      ''unclassified_minutes'', (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref IS NULL), 0) FROM ranked),' || E'\n' ||
'      -- mig 810. NOT added to recorded_minutes, and not part of any share' || E'\n' ||
'      -- computed from it. Reported so a reader can see how much of the' || E'\n' ||
'      -- portfolio was carried by people who are not staffed on it.' || E'\n' ||
'      ''support_minutes'',      (SELECT COALESCE(sum(support_minutes), 0) FROM ranked),' || E'\n' ||
'      ''supported_projects'',   (SELECT count(*) FROM ranked WHERE support_minutes > 0),' || E'\n';

  -- ── the row object ────────────────────────────────────────────────────────
  a_row CONSTANT text :=
'               ''consumed_pct'',      r.consumed_pct,' || E'\n' ||
'               ''status'',            r.status)' || E'\n';
  b_row CONSTANT text :=
'               ''consumed_pct'',      r.consumed_pct,' || E'\n' ||
'               ''support_minutes'',      r.support_minutes,' || E'\n' ||
'               ''support_contributors'', r.support_contributors,' || E'\n' ||
'               ''status'',            r.status)' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_project_summary';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 810: timesheet_report_project_summary not found. 766 must run first.';
  END IF;
  IF position('hdr_pm' IN v_src) = 0 OR position('mgd' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810: 770 must run first -- the support CTE reads the branches it added.';
  END IF;

  IF position('support_minutes' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 810: the project summary already reports support hours. Nothing to do.';
  ELSE
    v_new := v_src;

    v_hits := (length(v_new) - length(replace(v_new, a_agg, ''))) / length(a_agg);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 810: the agg CTE anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_agg, b_agg);

    v_hits := (length(v_new) - length(replace(v_new, a_fin, ''))) / length(a_fin);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 810: the final column anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_fin, b_fin);

    v_hits := (length(v_new) - length(replace(v_new, a_join, ''))) / length(a_join);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 810: the agg join anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_join, b_join);

    v_hits := (length(v_new) - length(replace(v_new, a_tot, ''))) / length(a_tot);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 810: the totals anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_tot, b_tot);

    v_hits := (length(v_new) - length(replace(v_new, a_row, ''))) / length(a_row);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 810: the row anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_row, b_row);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 810: the project summary now reports support hours beside each project.';
  END IF;
END $mig$;

COMMENT ON FUNCTION public.timesheet_report_project_summary(jsonb) IS
  'Project Summary (design doc s9). One row per project. consumed_pct is NULL '
  'when budget_hours is unset -- never 0. Hours are the hours of employees the '
  'caller may see, PLUS, for a caller holding timesheet.view_project, every '
  'hour on the projects they manage (mig 770). support_minutes is help given '
  'by people not staffed on the project (mig 810): reported beside the '
  'project''s own hours and never inside them, so it reaches neither '
  'recorded_minutes nor consumed_pct nor the billable split.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  v_p1  integer;
  v_cut integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_project_summary';

  -- It reports the help.
  IF position('sup_ent AS (' IN v_src) = 0 OR position('sup AS (' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: the support CTEs are missing.';
  END IF;
  IF position('LEFT   JOIN sup s  ON s.project_id = u.id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: support hours are not joined onto the project row.';
  END IF;
  IF position('''support_minutes'',      r.support_minutes,' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: the per-project row does not carry support_minutes.';
  END IF;
  IF position('''supported_projects''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: the totals do not report how many projects were helped.';
  END IF;

  -- And, the point of the whole thing: it does not COUNT the help. `ent` must
  -- still read exactly what it read before. A later edit that quietly folded
  -- support into the burn fails here rather than in a budget meeting.
  IF position('WHERE  e.project_id IS NOT NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: the ent CTE was altered. Support hours must never enter it.';
  END IF;
  -- The ent CTE runs from its own opening to the comment this migration
  -- inserted just after it. Slicing on 'sup_ent AS (' instead would swallow
  -- that comment, which mentions related_project_id, and the check would fail
  -- on its own explanation.
  v_p1  := position('  ent AS (' IN v_src);
  v_cut := position('-- mig 810. Help GIVEN' IN v_src);
  IF v_p1 = 0 OR v_cut = 0 OR v_cut <= v_p1 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: cannot locate the ent CTE to check it.';
  END IF;
  IF position('related_project_id' IN substring(v_src FROM v_p1 FOR v_cut - v_p1)) > 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: ent reads related_project_id. The burn would include help.';
  END IF;
  IF position('ELSE round((COALESCE(a.recorded_minutes, 0) / 60.0)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: consumed_pct no longer derives from agg alone.';
  END IF;
  IF position('sum(recorded_minutes) FILTER (WHERE type_ref = ''P001'')' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 810 FAILED: the billable split was altered.';
  END IF;

  RAISE NOTICE 'Migration 810 verified: support hours reported beside every project, and the ent CTE that computes the burn is untouched.';
END $mig$;

COMMIT;
