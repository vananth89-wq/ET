-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 722: keep planned_minutes true when the holiday calendar changes
--
-- Three problems, one root cause.
--
-- 1. timesheet_headers.holiday_calendar_id is a snapshot taken when the header
--    is auto-created. If HR assigns the calendar afterwards, the header keeps
--    NULL forever and the month never sees a single holiday. Observed on
--    Aug 2026: planned read 176h when Eid Al Adha on Sun 16 made it 168h.
--
-- 2. time_planned_minutes_for_date() (mig 718) resolves holidays through that
--    same snapshot, so the ENTRY-LEVEL RULES inherit the bug — the half-day and
--    leave checks in enforce_timesheet_entry_rules() think a holiday is an
--    ordinary 8h working day whenever the snapshot is stale.
--
-- 3. planned_minutes is only ever computed at creation. A holiday added,
--    moved or deleted later never reaches an existing header, so reports read
--    stale totals until each employee happens to open their timesheet.
--
-- Fixes, in order: resolve the calendar from employment (header as fallback),
-- backfill the stale snapshots, then recompute on every calendar change via a
-- trigger.
--
-- POLICY
--   planned_minutes is ALWAYS derived truth — recomputed for every status,
--   including approved. It is a denominator, not a decision: an approver
--   approves the employee's RECORDED attendance, and planned_minutes is
--   consumed nowhere else in the product (no payroll, no LOP, no shortfall
--   calculation). Freezing it would not protect an approval, it would only
--   leave a wrong total on screen beside a holiday the calendar does show.
--
--   status is what stays immutable:
--     to_be_submitted → recompute, no status change.
--     to_be_approved  → recompute AND return to the employee. An approver must
--                       never sign off a total that moved underneath them.
--     approved        → recompute, status/approved_at UNTOUCHED. Audited.
--
-- Known asymmetry: ADDING a holiday to an approved month lowers planned, which
-- corrects an employee's shortfall in their favour. REMOVING one raises it, so
-- someone approved as complete can retroactively look short with no chance to
-- fix it. Rare, and usually itself an error correction — the audit row records
-- both directions so it is traceable.
--
-- Note the timesheet submit flow is currently a bare column UPDATE — it does
-- not go through wf_submit — so nothing can reach 'approved' yet. When the real
-- approval step lands, reopening an approved sheet must withdraw its workflow
-- instance via wf_return_to_initiator, not flip a column, or the approver is
-- left holding a task pointing at a reopened timesheet.
-- time_holiday_calendar_changed() is where that call belongs.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Resolve the calendar from employment, not the header snapshot ────────
-- Accepts both effective_to conventions: 11 queries in this codebase use the
-- '9999-12-31' sentinel and at least one used NULL, so tolerate either.
CREATE OR REPLACE FUNCTION public.time_planned_minutes_for_date(p_header_id uuid, p_date date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ctx AS (
    SELECT h.work_schedule_id,
           COALESCE(
             (SELECT ee.holiday_calendar_id
                FROM   employee_employment ee
               WHERE  ee.employee_id = h.employee_id
                 AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                 AND  ee.holiday_calendar_id IS NOT NULL
               LIMIT 1),
             h.holiday_calendar_id
           ) AS calendar_id
    FROM timesheet_headers h
    WHERE h.id = p_header_id
  )
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM time_holidays th, ctx
       WHERE th.calendar_id  = ctx.calendar_id
         AND th.holiday_date = p_date
    ) THEN 0
    ELSE COALESCE((
      SELECT l.planned_minutes
      FROM   ctx
      JOIN   time_work_schedules      ws ON ws.id = ctx.work_schedule_id
      JOIN   time_work_schedule_lines l  ON l.work_schedule_id = ws.id
                 AND l.day_number = ((EXTRACT(DOW FROM p_date)::int - ws.start_day_of_week + 7) % 7) + 1
    ), 0)
  END;
$$;

REVOKE ALL ON FUNCTION public.time_planned_minutes_for_date(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_planned_minutes_for_date(uuid, date) TO authenticated;
COMMENT ON FUNCTION public.time_planned_minutes_for_date IS
  'Mig 722: planned minutes for a single date. Holidays return 0. The calendar '
  'is resolved from current employment, falling back to the header snapshot.';

-- ── 2. Backfill headers whose snapshot is stale or missing ─────────────────
DO $$
DECLARE v_fixed integer;
BEGIN
  UPDATE timesheet_headers h
     SET holiday_calendar_id = ee.holiday_calendar_id
    FROM employee_employment ee
   WHERE ee.employee_id = h.employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
     AND ee.holiday_calendar_id IS NOT NULL
     AND h.holiday_calendar_id IS DISTINCT FROM ee.holiday_calendar_id;
  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'Migration 722: backfilled holiday_calendar_id on % header(s).', v_fixed;
END $$;

-- ── 3. Recompute one header's planned_minutes ──────────────────────────────
CREATE OR REPLACE FUNCTION public.time_recalc_planned_minutes(p_header_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_period date;
  v_total  integer;
BEGIN
  SELECT period INTO v_period FROM timesheet_headers WHERE id = p_header_id;
  IF v_period IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(SUM(time_planned_minutes_for_date(p_header_id, d::date)), 0)
    INTO v_total
    FROM generate_series(v_period,
                         (v_period + INTERVAL '1 month' - INTERVAL '1 day')::date,
                         INTERVAL '1 day') AS d;

  UPDATE timesheet_headers
     SET planned_minutes = v_total
   WHERE id = p_header_id
     AND planned_minutes IS DISTINCT FROM v_total;

  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.time_recalc_planned_minutes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_recalc_planned_minutes(uuid) TO authenticated;
COMMENT ON FUNCTION public.time_recalc_planned_minutes IS
  'Mig 722: recompute timesheet_headers.planned_minutes from the live schedule '
  'and holiday calendar. Sums time_planned_minutes_for_date across the period.';

-- ── 4. Fan out over every header affected by a calendar change ─────────────
CREATE OR REPLACE FUNCTION public.time_holiday_calendar_changed(
  p_calendar_id uuid,
  p_period      date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r         record;
  v_new     integer;
  v_touched integer := 0;
BEGIN
  IF p_calendar_id IS NULL OR p_period IS NULL THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT h.id, h.employee_id, h.status, h.planned_minutes, h.submitted_at
      FROM timesheet_headers h
     WHERE h.period = p_period
       AND (
             h.holiday_calendar_id = p_calendar_id
          OR EXISTS (
               SELECT 1 FROM employee_employment ee
                WHERE ee.employee_id = h.employee_id
                  AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                  AND ee.holiday_calendar_id = p_calendar_id
             )
           )
  LOOP
    -- planned_minutes is derived truth for every status, approved included.
    v_new := time_recalc_planned_minutes(r.id);

    -- An approved sheet keeps its status and its approval stamp. Only the
    -- denominator moves, and only when it actually changed — audited so the
    -- shift is traceable, in either direction.
    IF r.status = 'approved' THEN
      IF v_new IS DISTINCT FROM r.planned_minutes THEN
        INSERT INTO employee_audit_log
          (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
        VALUES
          ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
           jsonb_build_object('status', r.status, 'planned_minutes', r.planned_minutes),
           jsonb_build_object('status', r.status,
                              'planned_minutes', v_new,
                              'reason', 'holiday_calendar_changed_after_approval',
                              'action', 'planned recomputed; approval left intact',
                              'calendar_id', p_calendar_id,
                              'period', p_period),
           auth.uid());
      END IF;
      v_touched := v_touched + 1;
      CONTINUE;
    END IF;

    -- Submitted but not yet approved: pull it back rather than let an approver
    -- sign off a total that changed underneath them.
    IF r.status = 'to_be_approved' THEN
      UPDATE timesheet_headers
         SET status = 'to_be_submitted', submitted_at = NULL
       WHERE id = r.id;

      INSERT INTO employee_audit_log
        (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
      VALUES
        ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
         jsonb_build_object('status', r.status,
                            'submitted_at', r.submitted_at,
                            'planned_minutes', r.planned_minutes),
         jsonb_build_object('status', 'to_be_submitted',
                            'submitted_at', NULL,
                            'planned_minutes', v_new,
                            'reason', 'holiday_calendar_changed',
                            'calendar_id', p_calendar_id,
                            'period', p_period),
         auth.uid());
    END IF;

    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_holiday_calendar_changed(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_holiday_calendar_changed(uuid, date) TO authenticated;
COMMENT ON FUNCTION public.time_holiday_calendar_changed IS
  'Mig 722: recompute planned_minutes for every header in a period using a '
  'calendar. Reopens to_be_approved sheets; freezes approved ones. Audited.';

-- ── 5. Fire it whenever the calendar changes ───────────────────────────────
-- Deliberately NOT bounded by the 6-month window used for the one-time backfill
-- below. This fires because a human edited a holiday in a specific month, which
-- is intent — silently ignoring a correction to an older month would be worse
-- than doing the work. It is also cheap: one period, index-served by
-- idx_ts_headers_period_status, only the headers on that calendar.
CREATE OR REPLACE FUNCTION public.trg_time_holidays_recalc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- New location of the holiday
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM time_holiday_calendar_changed(
      NEW.calendar_id, date_trunc('month', NEW.holiday_date)::date);
  END IF;

  -- Old location too, so moving a holiday across months or calendars restores
  -- the month it left. Skipped when nothing relevant moved.
  IF TG_OP = 'DELETE'
     OR (TG_OP = 'UPDATE'
         AND (OLD.holiday_date <> NEW.holiday_date OR OLD.calendar_id <> NEW.calendar_id)) THEN
    PERFORM time_holiday_calendar_changed(
      OLD.calendar_id, date_trunc('month', OLD.holiday_date)::date);
  END IF;

  RETURN NULL;   -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_time_holidays_recalc ON time_holidays;
CREATE TRIGGER trg_time_holidays_recalc
  AFTER INSERT OR UPDATE OR DELETE ON time_holidays
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_holidays_recalc();

-- ── 6. Repair headers that are already wrong, within the last 6 months ─────
-- A blind sweep over all history would scale with the age of the deployment for
-- no benefit: nobody reads planned_minutes on a two-year-old month, and it is a
-- migration-time cost paid while the deploy holds. Six months covers every
-- period anyone might still act on. Older months stay as they are until someone
-- edits a holiday in them, at which point the trigger repairs them precisely.
-- The verification in part 7 uses the SAME window — widen one and you must widen
-- the other, or the check aborts on a row this block never visited.
DO $$
DECLARE
  r        record;
  v_before integer;
  v_after  integer;
  v_fixed  integer := 0;
  v_seen   integer := 0;
  v_floor  date := (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months')::date;
BEGIN
  FOR r IN
    SELECT id, planned_minutes FROM timesheet_headers
     WHERE period >= v_floor
  LOOP
    v_seen   := v_seen + 1;
    v_before := r.planned_minutes;
    v_after  := time_recalc_planned_minutes(r.id);
    IF v_after IS DISTINCT FROM v_before THEN
      v_fixed := v_fixed + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Migration 722: scanned % header(s) since %, corrected %.',
               v_seen, v_floor, v_fixed;
END $$;

-- ── 7. Verify ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'trg_time_holidays_recalc'
       AND tgrelid = 'time_holidays'::regclass
  ) THEN
    RAISE EXCEPTION 'ABORT: trg_time_holidays_recalc not found on time_holidays.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'time_recalc_planned_minutes'
  ) THEN
    RAISE EXCEPTION 'ABORT: time_recalc_planned_minutes() not created.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'time_holiday_calendar_changed'
  ) THEN
    RAISE EXCEPTION 'ABORT: time_holiday_calendar_changed() not created.';
  END IF;

  -- The whole point of part 1: within the repaired window, no header may still
  -- disagree with what the live schedule and calendar say. Scoped to the same
  -- 6-month floor as part 6 — asserting over all history would abort on rows
  -- that block deliberately never visited.
  IF EXISTS (
    SELECT 1 FROM timesheet_headers h
     WHERE h.period >= (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months')::date
       AND h.planned_minutes IS DISTINCT FROM (
             SELECT COALESCE(SUM(time_planned_minutes_for_date(h.id, d::date)), 0)
               FROM generate_series(h.period,
                                    (h.period + INTERVAL '1 month' - INTERVAL '1 day')::date,
                                    INTERVAL '1 day') AS d)
  ) THEN
    RAISE EXCEPTION 'ABORT: a header inside the 6-month window still has a stale planned_minutes.';
  END IF;

  RAISE NOTICE 'Migration 722 verified: calendar resolved from employment, '
               'planned_minutes recomputed on every holiday change.';
END $$;
