-- =============================================================================
-- Migration : 20260817744_timesheet_reports.sql
-- Purpose   : The two timesheet reports behind /admin/reports.
--
-- WHY TWO, NOT ONE
--   Utilisation asks "where did the hours go". Compliance asks "who has not
--   logged any". They cannot share a table: compliance needs a row for an
--   employee who recorded nothing, and an entry-grain result set has no row for
--   that person. One screen trying to answer both ends up as a table nobody
--   trusts, so they are two functions and two catalog entries.
--
-- WHY IN THE DATABASE AT ALL
--   The Expense report reads everything and filters in the browser, including
--   its target population -- with a comment admitting that is a UX filter and
--   not a boundary. Migration 740 exists precisely because the client holds a
--   FLAT permission list and cannot see that a grant is scoped to Direct
--   Reports: client-side scoping is wrong in both directions. These reports
--   scope, aggregate and paginate here, and the client renders what it is given.
--
-- THE GRAIN, AND THE TRAP IT AVOIDS
--   Utilisation returns ONE ROW PER ENTRY, with that entry's activity rows
--   nested for drill-down. It does NOT return one row per activity.
--
--   Since 727 timesheet_entry_activities is the source of truth for project
--   time and timesheet_entries.hours_minutes is a mirror maintained by
--   time_sync_entry_from_activities(). Joining entries to activities and
--   summing the parent double-counts by the number of children; summing the
--   children loses every pre-727 entry, which has none. Reading the parent and
--   treating children as display detail is correct for both, and PART 4 asserts
--   the mirror actually holds rather than assuming it.
--
-- TWO DIFFERENT PERMISSION QUESTIONS
--   `timesheet_reports.view`  -- may you open a timesheet report at all
--   `timesheet` view scope    -- whose timesheets may you see in it
--   The second is deliberately NOT given its own module. Which employees appear
--   in a report is the same question as which timesheets you may read, and a
--   second answer to it is a second thing to keep in step.
--
-- Depends on : 704/705 (timesheet tables), 727 (activities), 730 (edit window),
--              738 (max_daily_minutes), 739 (timesheet_reports.view kept),
--              742 (approval), 743 (entry audit), 500 (get_target_population)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the scope helper, shared by both reports
-- ═══════════════════════════════════════════════════════════════════════════
-- Returns NULL for "no restriction" and an empty array for "nothing visible".
--
-- READ THAT AGAIN BEFORE USING IT. `x = ANY(NULL)` is NULL, not true, so a
-- NULL scope used bare filters every row away -- the exact opposite of what it
-- means. Every use must be written `(v_scope IS NULL OR col = ANY(v_scope))`.
-- The alternative -- returning every employee id for the unrestricted case --
-- would mean materialising the whole company on each call to say "no filter".

CREATE OR REPLACE FUNCTION public.time_report_scope()
RETURNS uuid[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pop jsonb;
BEGIN
  -- A super admin bypasses user_can() entirely, so it must bypass this too or
  -- the report would be the one screen they cannot read.
  IF is_super_admin() THEN
    RETURN NULL;
  END IF;

  v_pop := get_target_population('timesheet', 'view');

  IF v_pop->>'mode' = 'all' THEN
    RETURN NULL;
  END IF;

  IF v_pop->>'mode' = 'scoped' THEN
    RETURN ARRAY(SELECT jsonb_array_elements_text(v_pop->'ids')::uuid);
  END IF;

  RETURN '{}'::uuid[];   -- mode = 'none'
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_scope() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_scope() TO authenticated;

COMMENT ON FUNCTION public.time_report_scope() IS
  'Mig 744: the employee ids a timesheet report may show. NULL = unrestricted, '
  'empty array = nothing. Callers MUST write (scope IS NULL OR col = ANY(scope)).';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the due date, from configuration rather than from a guess
-- ═══════════════════════════════════════════════════════════════════════════
-- time_submission_config has held real offsets since 702 (-1, +3, +6 days from
-- month end) and has driven nothing, because the reminder cron was never built.
-- The compliance report reads it, so the deadline it reports and the reminder
-- an employee will eventually receive come from the same row. Hardcoding "due
-- at month end" here would guarantee they contradict each other later.
--
-- The LAST active offset is the deadline: earlier ones are nudges, and the
-- final message is the one that says HR has been notified. No active rows at
-- all means the last day of the month.

CREATE OR REPLACE FUNCTION public.time_submission_due_date(p_period date)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT ((date_trunc('month', p_period) + INTERVAL '1 month - 1 day')::date
          + COALESCE((SELECT max(offset_days)
                      FROM   time_submission_config
                      WHERE  is_active), 0));
$fn$;

REVOKE ALL ON FUNCTION public.time_submission_due_date(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_submission_due_date(date) TO authenticated;

COMMENT ON FUNCTION public.time_submission_due_date(date) IS
  'Mig 744: month end plus the last active time_submission_config offset. The '
  'one definition of a timesheet deadline -- wire any future reminder cron to '
  'this function rather than recomputing it.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — timesheet_report_utilisation
-- ═══════════════════════════════════════════════════════════════════════════
-- p_filters:
--   period_from   date    default = current month
--   period_to     date    default = period_from
--   employee_ids  uuid[]  default = no filter
--   dept_ids      uuid[]  default = no filter   (header snapshot, not live dept)
--   project_ids   uuid[]  default = no filter
--   time_type_ids uuid[]  default = no filter
--   categories    text[]  'attendance' | 'absence'
--   statuses      text[]  header status
--   include_system boolean default false  (holiday rows written by the system)
--   page          int     default 1
--   page_size     int     default 50, capped at 500
--
-- Totals are computed over the WHOLE filtered set, not the page -- a footer
-- that only totals the visible rows is a footer that lies at page 2.
--
-- planned_minutes comes from the matching HEADERS, never from the row set. It
-- is a per-month figure; summing it per entry would multiply it by the number
-- of entries in the month, which is how utilisation percentages end up under
-- ten percent and nobody can say why.

CREATE OR REPLACE FUNCTION public.timesheet_report_utilisation(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_scope     uuid[];
  v_from      date;
  v_to        date;
  v_emp       uuid[];
  v_dept      uuid[];
  v_proj      uuid[];
  v_tt        uuid[];
  v_cat       text[];
  v_status    text[];
  v_sys       boolean;
  v_page      integer;
  v_size      integer;
  v_total     integer;
  v_result    jsonb;
BEGIN
  IF NOT user_can('timesheet_reports', 'view', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to open timesheet reports.');
  END IF;

  v_scope := time_report_scope();

  v_from   := COALESCE((p_filters->>'period_from')::date, date_trunc('month', CURRENT_DATE)::date);
  v_from   := date_trunc('month', v_from)::date;
  v_to     := date_trunc('month', COALESCE((p_filters->>'period_to')::date, v_from))::date;
  IF v_to < v_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_RANGE',
      'message', 'The end month is before the start month.');
  END IF;

  v_emp    := CASE WHEN p_filters ? 'employee_ids'  THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'employee_ids')::uuid)  END;
  v_dept   := CASE WHEN p_filters ? 'dept_ids'      THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'dept_ids')::uuid)      END;
  v_proj   := CASE WHEN p_filters ? 'project_ids'   THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'project_ids')::uuid)   END;
  v_tt     := CASE WHEN p_filters ? 'time_type_ids' THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'time_type_ids')::uuid) END;
  v_cat    := CASE WHEN p_filters ? 'categories'    THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'categories'))          END;
  v_status := CASE WHEN p_filters ? 'statuses'      THEN ARRAY(SELECT jsonb_array_elements_text(p_filters->'statuses'))            END;
  v_sys    := COALESCE((p_filters->>'include_system')::boolean, false);
  v_page   := GREATEST(1, COALESCE((p_filters->>'page')::integer, 1));
  v_size   := LEAST(500, GREATEST(1, COALESCE((p_filters->>'page_size')::integer, 50)));

  -- Empty array from time_report_scope() means the caller may see nobody.
  IF v_scope IS NOT NULL AND cardinality(v_scope) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'total_rows', 0,
      'page', v_page, 'page_size', v_size,
      'totals', jsonb_build_object('recorded_minutes', 0, 'planned_minutes', 0,
                                   'entry_count', 0, 'employee_count', 0, 'project_count', 0),
      'scope', jsonb_build_object('mode', 'none'));
  END IF;

  WITH hdr AS (
    SELECT h.*
    FROM   timesheet_headers h
    WHERE  h.period BETWEEN v_from AND v_to
      AND  (v_scope  IS NULL OR h.employee_id   = ANY(v_scope))
      AND  (v_emp    IS NULL OR h.employee_id   = ANY(v_emp))
      AND  (v_dept   IS NULL OR h.department_id = ANY(v_dept))
      AND  (v_status IS NULL OR h.status        = ANY(v_status))
  ),
  ent AS (
    SELECT e.id, e.entry_date, e.entry_kind, e.hours_minutes, e.notes,
           e.project_id, e.time_type_id, e.is_system_generated,
           e.created_at, e.updated_at,
           h.id AS header_id, h.employee_id, h.period, h.status AS header_status,
           h.department_id, h.department_name
    FROM   timesheet_entries e
    JOIN   hdr h ON h.id = e.header_id
    LEFT   JOIN time_types tt ON tt.id = e.time_type_id
    WHERE  (v_proj IS NULL OR e.project_id   = ANY(v_proj))
      AND  (v_tt   IS NULL OR e.time_type_id = ANY(v_tt))
      AND  (v_cat  IS NULL OR tt.category    = ANY(v_cat))
      AND  (v_sys  OR NOT e.is_system_generated)
  )
  SELECT jsonb_build_object(
    'ok', true,
    'page', v_page,
    'page_size', v_size,
    'total_rows', (SELECT count(*) FROM ent),

    -- Whole-set totals. planned_minutes is read off the headers, once each.
    'totals', jsonb_build_object(
      'recorded_minutes', (SELECT COALESCE(sum(hours_minutes), 0) FROM ent),
      'planned_minutes',  (SELECT COALESCE(sum(planned_minutes), 0) FROM hdr),
      'entry_count',      (SELECT count(*) FROM ent),
      'employee_count',   (SELECT count(DISTINCT employee_id) FROM ent),
      'project_count',    (SELECT count(DISTINCT project_id) FROM ent WHERE project_id IS NOT NULL)
    ),

    'scope', jsonb_build_object('mode', CASE WHEN v_scope IS NULL THEN 'all' ELSE 'scoped' END,
                                'employee_count', CASE WHEN v_scope IS NULL THEN NULL ELSE cardinality(v_scope) END),

    'rows', COALESCE((
      SELECT jsonb_agg(r ORDER BY r->>'entry_date', r->>'employee_name', r->>'project_name')
      FROM (
        SELECT jsonb_build_object(
                 'entry_id',        x.id,
                 'entry_date',      x.entry_date,
                 'period',          x.period,
                 'employee_id',     x.employee_id,
                 'employee_name',   em.name,
                 'employee_code',   em.employee_id,
                 'department_name', x.department_name,
                 'header_id',       x.header_id,
                 'header_status',   x.header_status,
                 'project_id',      x.project_id,
                 'project_name',    pj.name,
                 'time_type_id',    x.time_type_id,
                 'time_type_name',  tt.name,
                 'time_type_code',  tt.code,
                 'category',        tt.category,
                 'hours_minutes',   x.hours_minutes,
                 'notes',           x.notes,
                 'is_system_generated', x.is_system_generated,

                 -- Detail, not arithmetic. Never sum this alongside
                 -- hours_minutes: for a post-727 entry they are the same hours
                 -- counted twice.
                 'activities', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                            'id',            a.id,
                            'activity_name', a.activity_name,
                            'hours_minutes', a.hours_minutes,
                            'display_order', a.display_order)
                          ORDER BY a.display_order, a.activity_name)
                   FROM timesheet_entry_activities a
                   WHERE a.entry_id = x.id), '[]'::jsonb)
               ) AS r
        FROM        ent x
        LEFT  JOIN  employees  em ON em.id = x.employee_id
        LEFT  JOIN  projects   pj ON pj.id = x.project_id
        LEFT  JOIN  time_types tt ON tt.id = x.time_type_id
        ORDER BY    x.entry_date, em.name, pj.name NULLS FIRST
        LIMIT       v_size
        OFFSET      (v_page - 1) * v_size
      ) s
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.timesheet_report_utilisation(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.timesheet_report_utilisation(jsonb) TO authenticated;

COMMENT ON FUNCTION public.timesheet_report_utilisation(jsonb) IS
  'Mig 744: one row per timesheet entry with its activities nested. Gated on '
  'timesheet_reports.view; scoped by the timesheet view target population. '
  'hours_minutes is the parent entry -- summing the nested activities as well '
  'double-counts every post-727 project entry.';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — timesheet_report_compliance
-- ═══════════════════════════════════════════════════════════════════════════
-- One row per (employee, period). It starts from EMPLOYEES and left-joins
-- headers, not the other way round -- an employee who never opened a timesheet
-- has no header, and they are the entire point of the report.
--
-- WHO IS EXPECTED TO HAVE ONE
--   An employment record overlapping the period, AND a work schedule on it.
--   Someone with no schedule has planned = 0 every day and cannot legitimately
--   log anything, so listing them as "not submitted" is noise that hides the
--   real chasing list. They get their own state, `not_configured`, because it
--   is a configuration error somebody should fix -- not something to hide.
--
--   No employment overlapping the period at all means they were not employed
--   that month. Those rows are dropped entirely rather than shown as a state:
--   a leaver is not late.
--
-- p_filters:
--   period_from  date    default = current month
--   period_to    date    default = period_from
--   employee_ids uuid[]
--   dept_ids     uuid[]  live employment department, NOT the header snapshot --
--                        an employee with no header has no snapshot to filter on
--   states       text[]  not_configured | not_started | to_be_submitted |
--                        to_be_approved | approved
--   only_overdue boolean default false
--   page, page_size

CREATE OR REPLACE FUNCTION public.timesheet_report_compliance(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_scope    uuid[];
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
  IF NOT user_can('timesheet_reports', 'view', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to open timesheet reports.');
  END IF;

  v_scope := time_report_scope();

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

  IF v_scope IS NOT NULL AND cardinality(v_scope) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb, 'total_rows', 0,
      'page', v_page, 'page_size', v_size,
      'summary', jsonb_build_object('expected', 0, 'not_configured', 0, 'not_started', 0,
                                    'to_be_submitted', 0, 'to_be_approved', 0,
                                    'approved', 0, 'overdue', 0),
      'scope', jsonb_build_object('mode', 'none'));
  END IF;

  WITH per AS (
    SELECT generate_series(v_from, v_to, INTERVAL '1 month')::date AS period
  ),
  base AS (
    SELECT e.id   AS employee_id,
           e.name AS employee_name,
           e.employee_id AS employee_code,
           e.manager_id,
           p.period
    FROM   employees e
    CROSS  JOIN per p
    WHERE  e.deleted_at IS NULL
      AND  e.status = 'Active'
      AND  (v_scope IS NULL OR e.id = ANY(v_scope))
      AND  (v_emp   IS NULL OR e.id = ANY(v_emp))
  ),
  -- The employment row in force during that month. LATERAL because effective
  -- dating means the answer differs per period, not per employee.
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
  rows AS (
    SELECT em.employee_id, em.employee_name, em.employee_code, em.period,
           em.work_schedule_id, em.dept_id,
           dp.name AS department_name,
           mg.name AS manager_name,
           ws.name AS schedule_name,
           h.id             AS header_id,
           h.status         AS header_status,
           h.planned_minutes,
           h.recorded_minutes,
           h.submitted_at,
           h.approved_at,
           h.workflow_instance_id,
           time_submission_due_date(em.period) AS due_date,
           CASE
             WHEN em.work_schedule_id IS NULL THEN 'not_configured'
             WHEN h.id IS NULL                THEN 'not_started'
             ELSE h.status
           END AS state,
           (SELECT count(DISTINCT te.entry_date)
              FROM timesheet_entries te
             WHERE te.header_id = h.id
               AND NOT COALESCE(te.is_system_generated, false)) AS days_with_entries,
           -- Changes an approver has not signed off. approved_at is restamped
           -- on every approval by wf_sync_module_status, so it is the last one.
           --
           -- System rows are excluded from the ADDED half: a holiday written by
           -- the sync is not something an approver failed to sign off, and
           -- counting it would put a permanent 1 beside every approved month
           -- containing a public holiday. Found by test C15, which is the only
           -- reason this line is here.
           --
           -- The audit half cannot be filtered the same way -- 743's table
           -- carries no is_system_generated column, only the prior image. System
           -- rows are not edited by hand, so that is a theoretical overcount
           -- rather than the systematic one above.
           CASE WHEN h.approved_at IS NULL THEN NULL ELSE (
             (SELECT count(*) FROM timesheet_entry_audit ta
               WHERE ta.header_id = h.id AND ta.created_at > h.approved_at)
           + (SELECT count(*) FROM timesheet_entries te2
               WHERE te2.header_id = h.id AND te2.created_at > h.approved_at
                 AND NOT COALESCE(te2.is_system_generated, false))
           ) END AS changes_since_approval
    FROM       emp em
    LEFT  JOIN timesheet_headers    h  ON h.employee_id = em.employee_id AND h.period = em.period
    LEFT  JOIN departments          dp ON dp.id = em.dept_id
    LEFT  JOIN employees            mg ON mg.id = em.manager_id
    LEFT  JOIN time_work_schedules  ws ON ws.id = em.work_schedule_id
    WHERE em.employed                                  -- a leaver is not late
      AND (v_dept IS NULL OR em.dept_id = ANY(v_dept))
  ),
  flagged AS (
    SELECT r.*,
           (r.state IN ('not_started', 'to_be_submitted') AND CURRENT_DATE > r.due_date) AS is_overdue,
           GREATEST(0, CURRENT_DATE - r.due_date) AS days_past_due
    FROM   rows r
  ),
  final AS (
    SELECT f.* FROM flagged f
    WHERE (v_states IS NULL OR f.state = ANY(v_states))
      AND (NOT v_overdue OR f.is_overdue)
  )
  SELECT jsonb_build_object(
    'ok', true,
    'page', v_page,
    'page_size', v_size,
    'total_rows', (SELECT count(*) FROM final),

    'summary', jsonb_build_object(
      'expected',        (SELECT count(*) FROM final WHERE state <> 'not_configured'),
      'not_configured',  (SELECT count(*) FROM final WHERE state = 'not_configured'),
      'not_started',     (SELECT count(*) FROM final WHERE state = 'not_started'),
      'to_be_submitted', (SELECT count(*) FROM final WHERE state = 'to_be_submitted'),
      'to_be_approved',  (SELECT count(*) FROM final WHERE state = 'to_be_approved'),
      'approved',        (SELECT count(*) FROM final WHERE state = 'approved'),
      'overdue',         (SELECT count(*) FROM final WHERE is_overdue),
      'planned_minutes',  (SELECT COALESCE(sum(planned_minutes), 0)  FROM final),
      'recorded_minutes', (SELECT COALESCE(sum(recorded_minutes), 0) FROM final)
    ),

    'scope', jsonb_build_object('mode', CASE WHEN v_scope IS NULL THEN 'all' ELSE 'scoped' END,
                                'employee_count', CASE WHEN v_scope IS NULL THEN NULL ELSE cardinality(v_scope) END),

    'rows', COALESCE((
      SELECT jsonb_agg(r ORDER BY r->>'period', r->>'employee_name')
      FROM (
        SELECT jsonb_build_object(
                 'employee_id',      f.employee_id,
                 'employee_name',    f.employee_name,
                 'employee_code',    f.employee_code,
                 'manager_name',     f.manager_name,
                 'department_name',  f.department_name,
                 'schedule_name',    f.schedule_name,
                 'period',           f.period,
                 'state',            f.state,
                 'header_id',        f.header_id,
                 'header_status',    f.header_status,
                 'planned_minutes',  COALESCE(f.planned_minutes, 0),
                 'recorded_minutes', COALESCE(f.recorded_minutes, 0),
                 'variance_minutes', COALESCE(f.recorded_minutes, 0) - COALESCE(f.planned_minutes, 0),
                 'days_with_entries', COALESCE(f.days_with_entries, 0),
                 'submitted_at',     f.submitted_at,
                 'approved_at',      f.approved_at,
                 'due_date',         f.due_date,
                 'is_overdue',       f.is_overdue,
                 'days_past_due',    CASE WHEN f.is_overdue THEN f.days_past_due ELSE 0 END,
                 'changes_since_approval', f.changes_since_approval,
                 'workflow_instance_id',   f.workflow_instance_id
               ) AS r
        FROM     final f
        ORDER BY f.period, f.employee_name
        LIMIT    v_size
        OFFSET   (v_page - 1) * v_size
      ) s
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.timesheet_report_compliance(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.timesheet_report_compliance(jsonb) TO authenticated;

COMMENT ON FUNCTION public.timesheet_report_compliance(jsonb) IS
  'Mig 744: one row per (employee, period), starting from employees so that '
  'someone who logged nothing still appears. States: not_configured (no work '
  'schedule), not_started (no header), then the three header statuses. Due '
  'date comes from time_submission_due_date().';


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_drift   integer;
  v_secdef  boolean;
BEGIN
  -- The permission these reports are gated on must exist, or the screens ship
  -- unreachable. 739 kept timesheet_reports.view deliberately; this is the
  -- migration that makes that decision pay off, so it is also the one that
  -- should fail loudly if it went missing in between.
  IF NOT EXISTS (
    SELECT 1 FROM permissions p JOIN modules m ON m.id = p.module_id
    WHERE m.code = 'timesheet_reports' AND p.action = 'view'
  ) THEN
    v_missing := v_missing || 'timesheet_reports.view is not in the permission catalog'::text;
  END IF;

  FOR v_secdef IN
    SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('time_report_scope', 'time_submission_due_date',
                        'timesheet_report_utilisation', 'timesheet_report_compliance')
  LOOP
    IF NOT v_secdef THEN
      v_missing := v_missing || 'a mig 744 function is not SECURITY DEFINER'::text;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('time_report_scope', 'time_submission_due_date',
                          'timesheet_report_utilisation', 'timesheet_report_compliance')) <> 4 THEN
    v_missing := v_missing || 'mig 744 did not create all four functions'::text;
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 744 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  -- ── The 727 mirror ──────────────────────────────────────────────────────
  -- Utilisation reads timesheet_entries.hours_minutes and shows the activity
  -- rows underneath it. If time_sync_entry_from_activities() has ever failed to
  -- keep them in step, the total and the drill-down disagree and neither is
  -- obviously wrong to the reader.
  --
  -- A WARNING, not an abort, and deliberately so: this checks DATA, not schema.
  -- Refusing to deploy a report because one historical row drifted would block
  -- the tool you would use to find it. Entries with no activity rows are
  -- excluded -- pre-727 rows have none by definition and are not drift.
  SELECT count(*) INTO v_drift
  FROM (
    SELECT e.id
    FROM   timesheet_entries e
    JOIN   timesheet_entry_activities a ON a.entry_id = e.id
    GROUP  BY e.id, e.hours_minutes
    HAVING sum(a.hours_minutes) <> e.hours_minutes
  ) d;

  IF v_drift > 0 THEN
    RAISE WARNING 'MIG 744: % entr(y/ies) disagree with the sum of their activity rows. '
                  'The utilisation total and its drill-down will not match for those. '
                  'Find them with: SELECT e.id FROM timesheet_entries e JOIN '
                  'timesheet_entry_activities a ON a.entry_id = e.id GROUP BY e.id, '
                  'e.hours_minutes HAVING sum(a.hours_minutes) <> e.hours_minutes;', v_drift;
  ELSE
    RAISE NOTICE 'MIG 744: the 727 mirror holds -- every itemised entry equals the sum of its activities.';
  END IF;

  RAISE NOTICE 'MIG 744 verified: utilisation and compliance reports created, gated on timesheet_reports.view.';
END $mig$;

COMMIT;
