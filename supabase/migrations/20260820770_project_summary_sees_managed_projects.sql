-- =============================================================================
-- Migration : 20260820770_project_summary_sees_managed_projects.sql
-- Purpose   : Wire the PM predicate (767) into the Project Summary report --
--             the FIRST reader, and deliberately the simplest one.
--
-- WHY PROJECT SUMMARY FIRST, AND UTILISATION SEPARATELY
--   Utilisation is grained on the ENTRY, so widening it means individual rows
--   about individual people become visible to someone outside their HR scope,
--   which needs per-row redaction of department and planned hours and a visible
--   "columns hidden" notice. Project Summary is grained on the PROJECT: the only
--   employee-derived figure is contributor_count, a number, not an identity.
--
--   So this migration delivers the whole point of the persona -- a PM sees the
--   TRUE total for their project instead of a fraction of it -- while carrying
--   none of the redaction risk. Utilisation follows in its own migration, and
--   can be reviewed on its own merits rather than buried under this one.
--
-- THE RULE, IN ONE LINE
--   An entry counts if the employee is in my scope, OR the project is one I
--   manage. The two halves are UNION ALL'd as DISJOINT sets -- the PM branch
--   excludes employees already visible through scope -- so there is no dedupe
--   sort, and no entry is counted twice.
--
-- WHY A SECOND BRANCH AND NOT ONE WIDER PREDICATE
--   746 measured the scoped path at 15ms against 1,381ms, and the win came from
--   the scope semi-join pruning headers before anything else runs. Folding
--   `OR <project test>` into that predicate would defeat the prune for EVERY
--   caller, including the overwhelming majority who manage nothing. As a
--   separate branch guarded by v_pm, a non-PM's branch reduces to a constant
--   false, Postgres skips it whole, and branch one keeps the plan it has today.
--
-- SCOPE 'none' IS NO LONGER AN EARLY RETURN FOR A PM
--   766 returned an empty envelope the moment scope was 'none'. A project
--   manager with no employee population is a real configuration -- an external
--   delivery lead, say -- and it is exactly the person this feature exists for.
--   The early return now requires NOT v_pm.
--
-- Depends on : 766 (this function), 767 (the predicate)
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.timesheet_report_project_summary(
  p_filters jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET jit TO 'off'
AS $function$
DECLARE
  v_mode   text;
  v_pm     boolean;
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
  -- 767. False for everyone without the grant, which keeps the PM branch out of
  -- the plan entirely for almost every run.
  v_pm   := time_report_is_project_manager();

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

  -- 'none' means no employee population. For a project manager that is not the
  -- same as "sees nothing" -- their access comes from the project, not the
  -- population -- so the early return applies only to non-managers.
  IF v_mode = 'none' AND NOT v_pm THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'total_rows', 0,
      'page', v_page, 'page_size', v_size,
      'totals', jsonb_build_object(
        'recorded_minutes', 0, 'billable_minutes', 0, 'internal_minutes', 0,
        'overhead_minutes', 0, 'unclassified_minutes', 0,
        'project_count', 0, 'contributor_count', 0,
        'budgeted_projects', 0, 'unclassified_projects', 0,
        'over_budget_projects', 0, 'unmanaged_projects', 0),
      'pm', jsonb_build_object('is_manager', false, 'managed_projects', 0),
      'scope', jsonb_build_object('mode', 'none'));
  END IF;

  WITH scope AS MATERIALIZED (
    SELECT s.employee_id FROM time_report_scope_ids() s
  ),
  mgd AS MATERIALIZED (
    SELECT m.project_id FROM time_report_managed_project_ids() m
  ),
  -- Branch one: unchanged. The scope semi-join still prunes headers first.
  hdr AS (
    SELECT h.id, h.employee_id
    FROM   timesheet_headers h
    WHERE  h.period BETWEEN v_from AND v_to
      AND  (v_mode = 'all' OR h.employee_id IN (SELECT employee_id FROM scope))
      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))
      AND  (v_dept   IS NULL OR h.department_id = ANY(v_dept))
      AND  (v_status IS NULL OR h.status        = ANY(v_status))
  ),
  -- Branch two: entries on projects this caller MANAGES, by employees the
  -- caller cannot otherwise see. Guarded by v_pm, so for a non-manager this
  -- collapses to a constant-false qualifier and is skipped whole.
  hdr_pm AS (
    SELECT h.id, h.employee_id
    FROM   timesheet_headers h
    WHERE  v_pm
      AND  h.period BETWEEN v_from AND v_to
      AND  NOT (v_mode = 'all' OR h.employee_id IN (SELECT employee_id FROM scope))
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
    UNION ALL
    -- Disjoint from the set above by construction: hdr_pm excludes every
    -- employee hdr admits. No dedupe, and no hour counted twice.
    SELECT e.project_id, e.hours_minutes, e.entry_date, h.employee_id
    FROM   timesheet_entries e
    JOIN   hdr_pm h ON h.id = e.header_id
    WHERE  e.project_id IN (SELECT project_id FROM mgd)
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
  universe AS (
    SELECT p.*
    FROM   projects p
    WHERE  (p.id IN (SELECT project_id FROM agg))
       -- A manager always sees their own projects, whatever their dates or
       -- active flag. Hiding a project from the person accountable for it
       -- because it closed last month is not a security property.
       OR  (p.id IN (SELECT project_id FROM mgd))
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
           (u.id IN (SELECT project_id FROM mgd)) AS i_manage,
           COALESCE(a.recorded_minutes,  0) AS recorded_minutes,
           COALESCE(a.entry_count,       0) AS entry_count,
           COALESCE(a.contributor_count, 0) AS contributor_count,
           COALESCE(a.months_active,     0) AS months_active,
           a.first_entry,
           a.last_entry,
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

    'totals', jsonb_build_object(
      'recorded_minutes',     (SELECT COALESCE(sum(recorded_minutes), 0) FROM ranked),
      'billable_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P001'), 0) FROM ranked),
      'internal_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P002'), 0) FROM ranked),
      'overhead_minutes',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = 'P003'), 0) FROM ranked),
      'unclassified_minutes', (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref IS NULL), 0) FROM ranked),
      'project_count',        (SELECT count(*) FROM ranked),
      'contributor_count',    (SELECT count(DISTINCT employee_id) FROM ent),
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
               'i_manage',          r.i_manage,
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

    -- So the screen can say WHY a row is visible, instead of the reader
    -- wondering why one project's total dwarfs what their scope should allow.
    'pm', jsonb_build_object(
      'is_manager',       v_pm,
      'managed_projects', (SELECT count(*) FROM mgd)),

    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'scope',  jsonb_build_object('mode', v_mode)
  ) INTO v_result;

  RETURN v_result;
END
$function$;

COMMENT ON FUNCTION public.timesheet_report_project_summary(jsonb) IS
  'Project Summary (design doc s9). One row per project. consumed_pct is NULL '
  'when budget_hours is unset -- never 0. Hours are the hours of employees the '
  'caller may see, PLUS, for a caller holding timesheet.view_project, every '
  'hour on the projects they manage (mig 770).';

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

  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    v_missing := v_missing || 'the report does not read the PM predicate'::text; END IF;
  IF position('UNION ALL' IN v_src) = 0 THEN
    v_missing := v_missing || 'the PM branch was folded into the scope predicate, which defeats the semi-join prune 746 measured'::text; END IF;
  IF position('v_mode = ''none'' AND NOT v_pm' IN v_src) = 0 THEN
    v_missing := v_missing || 'scope none still short-circuits a project manager'::text; END IF;

  -- 766 must survive intact.
  IF position('''timesheet_reports'', ''view_projects''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 766: the report permission gate was dropped'::text; END IF;
  IF position('THEN NULL' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 766: consumed_pct must stay NULL without a budget'::text; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_project_summary'
      AND 'jit=off' = ANY(COALESCE(p.proconfig, '{}'))
  ) THEN
    v_missing := v_missing || 'mig 746: SET jit = off was lost'::text; END IF;

  -- Utilisation must NOT have been widened by this migration.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation'
      AND pg_get_functiondef(p.oid) LIKE '%time_report_managed_project_ids%'
  ) THEN
    v_missing := v_missing || 'utilisation was widened here -- it needs per-row redaction and its own migration'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 770 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 770 verified: a project manager sees the true total for the projects they manage.';
END $mig$;

COMMIT;
