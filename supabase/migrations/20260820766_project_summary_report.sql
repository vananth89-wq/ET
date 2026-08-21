-- =============================================================================
-- Migration : 20260820766_project_summary_report.sql
-- Purpose   : The Project Summary report -- design doc s9. One row per project:
--             hours, budget, consumption, contributors, and a status that says
--             "No budget set" out loud rather than inventing a percentage.
--
-- WHAT MAKES THIS REPORT DIFFERENT FROM UTILISATION
--   Utilisation is grained on the ENTRY and answers "where did the hours go".
--   This is grained on the PROJECT and answers "how is each project doing
--   against what it was given". The denominator is projects.budget_hours (mig
--   754), which is the first denominator in this suite that is actually about
--   a project -- s8.1b exists precisely because planned_minutes is not.
--
-- WHICH PROJECTS APPEAR
--   Every ACTIVE project whose dates overlap the reported period, UNION every
--   project with entries in the filtered set. The second half catches a closed
--   or out-of-range project that still received hours. The first half catches a
--   budgeted project nobody logged to -- which reads as 0% consumed and is a
--   real finding, not noise. A report that only listed projects with hours
--   would silently drop exactly the projects worth asking about.
--
-- NO PER-PROJECT "BILLABLE %" -- A CORRECTION TO s9
--   s9 lists Billable % in the project health strip. That was written before
--   project_type landed on the PROJECT: a project is entirely one type, so its
--   billable share is 100% or 0% and the column carries no information. The
--   meaningful figure is the PORTFOLIO billable share, which is in `totals`.
--   Per-project billable time needs a type on the ENTRY, which does not exist.
--
-- CONSUMPTION IS NULL WHEN THERE IS NO BUDGET, NEVER ZERO
--   `consumed_pct` is NULL for an unbudgeted project and sorts last, because 0%
--   would rank it as the healthiest thing in the portfolio -- the exact
--   inversion of the truth. s9.1 sets out the rule for every surface.
--
-- SCOPE  Hours come through timesheet_headers, so they are the hours of
--   employees the caller may see. A project's total here is not necessarily the
--   project's total. The envelope returns `scope` so the screen can say so.
--
-- Depends on : 745 (permission mechanism), 746 (scope helpers), 754 (budget,
--              manager), 755/758 (project type picklist)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0  Widen permissions_action_check FIRST
--
-- Same mechanism as 732 and 745, and for the same reason: permissions.action is
-- an enumerated allow-list, and 745 failed on Dev with 23514 by forgetting it.
-- The new constraint is the canonical list PLUS whatever the column already
-- holds, so a replay against a database carrying a value this migration did not
-- create cannot fail on a difference it has no business adjudicating.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_canonical text[] := ARRAY['view','create','edit','delete','history','lookup',
                              'view_all_pending','edit_all_pending',
                              'bulk_import','bulk_export',
                              'view_inactive','reassign','approve',
                              'view_compliance','view_utilisation',
                              'view_projects',
                              'view_capacity','view_analytics'];
  v_extra     text[];
  v_allowed   text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[])
    INTO v_extra
  FROM   public.permissions
  WHERE  action IS NOT NULL
    AND  action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 766: permissions.action holds % value(s) outside the canonical '
                  'set: %. Preserved rather than rejected.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;

  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format(
    'ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
    'CHECK (action = ANY (%L::text[]))', v_allowed);

  RAISE NOTICE 'MIG 766: permissions_action_check now admits % value(s).',
               array_length(v_allowed, 1);
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  The permission
--
-- Seeded only now, with its screen. 739 spent a whole migration removing
-- permissions an administrator could grant that did nothing.
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet_reports.view_projects',
       'Project Summary Report',
       'Open the Project Summary report -- hours, budget consumption and '
       'contributors per project. Hours are still limited to the employees the '
       'Timesheet view target population allows; this grant opens the report, '
       'not the population.',
       'view_projects',
       30
FROM   public.modules m
WHERE  m.code = 'timesheet_reports'
ON CONFLICT (code) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  The report
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.timesheet_report_project_summary(
  p_filters jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET jit TO 'off'          -- 746: a set-returning body defaults to 1,000 est. rows,
AS $function$             --      clears jit_above_cost, and pays 1.5s to compile.
DECLARE
  v_mode   text;
  v_from   date;
  v_to     date;
  v_last   date;
  v_emp    uuid[];
  v_dept   uuid[];
  v_proj   uuid[];
  v_status text[];
  v_types  uuid[];
  v_sys    boolean;
  v_sort   text;
  v_page   integer;
  v_size   integer;
  v_result jsonb;
BEGIN
  IF NOT user_can('timesheet_reports', 'view_projects', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to open timesheet reports.');
  END IF;

  v_mode := time_report_scope_mode();

  v_from := COALESCE((p_filters->>'period_from')::date, date_trunc('month', CURRENT_DATE)::date);
  v_from := date_trunc('month', v_from)::date;
  v_to   := date_trunc('month', COALESCE((p_filters->>'period_to')::date, v_from))::date;
  IF v_to < v_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_RANGE',
      'message', 'The end month is before the start month.');
  END IF;
  v_last := (v_to + interval '1 month')::date - 1;

  v_emp    := CASE WHEN p_filters ? 'employee_ids' THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'employee_ids')::uuid) END;
  v_dept   := CASE WHEN p_filters ? 'dept_ids'     THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'dept_ids')::uuid)     END;
  v_proj   := CASE WHEN p_filters ? 'project_ids'  THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'project_ids')::uuid)  END;
  v_types  := CASE WHEN p_filters ? 'type_ids'     THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'type_ids')::uuid)     END;
  v_status := CASE WHEN p_filters ? 'statuses'     THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'statuses'))           END;
  v_sys    := COALESCE((p_filters->>'include_system')::boolean, false);
  v_sort   := COALESCE(p_filters->>'sort', 'hours');
  v_page   := GREATEST(1, COALESCE((p_filters->>'page')::integer, 1));
  v_size   := LEAST(500, GREATEST(1, COALESCE((p_filters->>'page_size')::integer, 50)));

  IF v_mode = 'none' THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'total_rows', 0,
      'page', v_page, 'page_size', v_size,
      'totals', jsonb_build_object(
        'recorded_minutes', 0, 'billable_minutes', 0, 'internal_minutes', 0,
        'overhead_minutes', 0, 'unclassified_minutes', 0,
        'project_count', 0, 'contributor_count', 0,
        'budgeted_projects', 0, 'unclassified_projects', 0),
      'scope', jsonb_build_object('mode', 'none'));
  END IF;

  WITH scope AS MATERIALIZED (
    SELECT s.employee_id FROM time_report_scope_ids() s
  ),
  hdr AS (
    SELECT h.id, h.employee_id
    FROM   timesheet_headers h
    WHERE  h.period BETWEEN v_from AND v_to
      AND  (v_mode = 'all' OR h.employee_id IN (SELECT employee_id FROM scope))
      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))
      AND  (v_dept   IS NULL OR h.department_id = ANY(v_dept))
      AND  (v_status IS NULL OR h.status        = ANY(v_status))
  ),
  ent AS (
    SELECT e.project_id, e.hours_minutes, e.entry_date, h.employee_id
    FROM   timesheet_entries e
    JOIN   hdr h ON h.id = e.header_id
    WHERE  e.project_id IS NOT NULL
      AND  (v_sys OR NOT e.is_system_generated)
  ),
  agg AS (
    SELECT en.project_id,
           sum(en.hours_minutes)::bigint          AS recorded_minutes,
           count(*)::bigint                       AS entry_count,
           count(DISTINCT en.employee_id)::bigint AS contributor_count,
           count(DISTINCT date_trunc('month', en.entry_date))::bigint AS months_active,
           min(en.entry_date)                     AS first_entry,
           max(en.entry_date)                     AS last_entry
    FROM   ent en
    GROUP  BY 1
  ),
  -- The portfolio for this period: active projects that overlap it, plus any
  -- project that actually received hours, however it is dated or flagged.
  universe AS (
    SELECT p.*
    FROM   projects p
    WHERE  (p.id IN (SELECT project_id FROM agg))
       OR  (p.active
            AND COALESCE(p.start_date, '-infinity'::date) <= v_last
            AND COALESCE(p.end_date,   'infinity'::date)  >= v_from)
  ),
  final AS (
    SELECT u.id            AS project_id,
           u.name          AS project_name,
           u.active,
           u.start_date,
           u.end_date,
           u.budget_hours,
           pv.ref_id       AS type_ref,
           pv.value        AS type_label,
           u.manager_id,
           em.name         AS manager_name,
           em.employee_id  AS manager_code,
           COALESCE(a.recorded_minutes,  0) AS recorded_minutes,
           COALESCE(a.entry_count,       0) AS entry_count,
           COALESCE(a.contributor_count, 0) AS contributor_count,
           COALESCE(a.months_active,     0) AS months_active,
           a.first_entry,
           a.last_entry,
           -- NULL, never 0, when there is nothing to divide by.
           CASE WHEN u.budget_hours IS NULL OR u.budget_hours <= 0 THEN NULL
                ELSE round((COALESCE(a.recorded_minutes, 0) / 60.0)
                           / u.budget_hours * 100, 1)
           END AS consumed_pct
    FROM   universe u
    LEFT   JOIN agg a  ON a.project_id = u.id
    LEFT   JOIN picklist_values pv ON pv.id = u.project_type_id
    LEFT   JOIN employees em       ON em.id = u.manager_id
    WHERE  (v_proj  IS NULL OR u.id             = ANY(v_proj))
      AND  (v_types IS NULL OR u.project_type_id = ANY(v_types))
  ),
  ranked AS (
    SELECT f.*,
           CASE
             WHEN f.consumed_pct IS NULL  THEN 'no_budget'
             WHEN f.consumed_pct > 100    THEN 'over_budget'
             WHEN f.consumed_pct >= 85    THEN 'near_budget'
             ELSE 'on_track'
           END AS status,
           row_number() OVER (
             ORDER BY
               CASE WHEN v_sort = 'name'     THEN f.project_name END ASC,
               CASE WHEN v_sort = 'consumed' THEN f.consumed_pct END DESC NULLS LAST,
               CASE WHEN v_sort = 'budget'   THEN f.budget_hours END DESC NULLS LAST,
               CASE WHEN v_sort NOT IN ('name','consumed','budget')
                    THEN f.recorded_minutes END DESC,
               f.project_name ASC
           ) AS rn
    FROM   final f
  )
  SELECT jsonb_build_object(
    'ok', true,
    'page', v_page,
    'page_size', v_size,
    'sort', v_sort,
    'total_rows', (SELECT count(*) FROM ranked),

    -- Computed over the WHOLE filtered portfolio, never the page.
    'totals', jsonb_build_object(
      'recorded_minutes',     (SELECT COALESCE(sum(recorded_minutes), 0) FROM ranked),
      'billable_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P001'), 0) FROM ranked),
      'internal_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P002'), 0) FROM ranked),
      'overhead_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P003'), 0) FROM ranked),
      'unclassified_minutes', (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref IS NULL), 0) FROM ranked),
      'project_count',        (SELECT count(*) FROM ranked),
      'contributor_count',    (SELECT count(DISTINCT employee_id) FROM ent),
      -- Both sent so the screen can say "budget shown for 3 of 8 projects"
      -- instead of implying the roll-up covers everything.
      'budgeted_projects',    (SELECT count(*) FROM ranked WHERE budget_hours IS NOT NULL),
      'unclassified_projects',(SELECT count(*) FROM ranked WHERE type_ref IS NULL),
      'over_budget_projects', (SELECT count(*) FROM ranked WHERE status = 'over_budget'),
      'unmanaged_projects',   (SELECT count(*) FROM ranked WHERE manager_id IS NULL)
    ),

    'rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'project_id',        r.project_id,
               'project_name',      r.project_name,
               'active',            r.active,
               'start_date',        r.start_date,
               'end_date',          r.end_date,
               'type_ref',          r.type_ref,
               'type_label',        r.type_label,
               'manager_id',        r.manager_id,
               'manager_name',      r.manager_name,
               'manager_code',      r.manager_code,
               'recorded_minutes',  r.recorded_minutes,
               'entry_count',       r.entry_count,
               'contributor_count', r.contributor_count,
               'months_active',     r.months_active,
               'first_entry',       r.first_entry,
               'last_entry',        r.last_entry,
               'budget_hours',      r.budget_hours,
               'consumed_pct',      r.consumed_pct,
               'status',            r.status)
             ORDER BY r.rn)
      FROM   ranked r
      WHERE  r.rn > (v_page - 1) * v_size AND r.rn <= v_page * v_size), '[]'::jsonb),

    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'scope',  jsonb_build_object('mode', v_mode)
  ) INTO v_result;

  RETURN v_result;
END
$function$;

COMMENT ON FUNCTION public.timesheet_report_project_summary(jsonb) IS
  'Project Summary (design doc s9). One row per project in the reported period. '
  'consumed_pct is NULL when budget_hours is unset -- never 0, which would rank '
  'an unbudgeted project as the healthiest in the portfolio. Hours are limited '
  'to the employees the caller may see, so a project total here is not '
  'necessarily the project total.';

GRANT EXECUTE ON FUNCTION public.timesheet_report_project_summary(jsonb) TO authenticated;

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
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_project_summary';

  IF v_src IS NULL THEN
    v_missing := v_missing || 'the report function was not created'::text;
  ELSE
    IF position('''timesheet_reports'', ''view_projects''' IN v_src) = 0 THEN
      v_missing := v_missing || 'the report does not check its own permission'::text; END IF;
    IF position('time_report_scope_mode' IN v_src) = 0 THEN
      v_missing := v_missing || 'the report is not scoped'::text; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code = 'timesheet_reports.view_projects') THEN
    v_missing := v_missing || 'the view_projects permission was not seeded'::text; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_project_summary'
      AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
  ) THEN
    v_missing := v_missing || 'SET jit = off is missing -- 746 measured 1.5s of compilation without it'::text; END IF;

  -- The sibling reports must be untouched.
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'timesheet_report_utilisation') THEN
    v_missing := v_missing || 'timesheet_report_utilisation disappeared'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'timesheet_report_compliance') THEN
    v_missing := v_missing || 'timesheet_report_compliance disappeared'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 766 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 766 verified: Project Summary is live and gated on timesheet_reports.view_projects.';
END $mig$;

COMMIT;
