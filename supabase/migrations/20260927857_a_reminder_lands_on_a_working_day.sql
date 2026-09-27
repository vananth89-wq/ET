-- =============================================================================
-- Migration 857 — a reminder lands on a working day
--
-- Reminder offsets in time_submission_config are counted in calendar days, so
-- "+1 day after period end" fires on a Sunday, or on Diwali, and the person it
-- was written for reads it on Monday alongside the next one. They should be
-- counted in WORKING days, pushed forward.
--
-- Working days are not a global fact in this system. Both inputs are
-- per-employee: the work schedule (time_work_schedule_lines -- a 5-day week and
-- a 6-day week disagree about Saturday) and the holiday calendar
-- (employee_employment.holiday_calendar_id -- India and the UK disagree about
-- most of the year). So "period end + 2 working days" is a DIFFERENT CALENDAR
-- DATE for different employees, and a reminder job cannot compute one firing
-- date per rule. It has to ask, per employee, what date that rule resolves to.
--
-- The existing answer cannot be reused. time_planned_minutes_for_date() (718,
-- corrected by 722) is the one definition of a working day, but it is keyed on
-- a TIMESHEET HEADER -- and the people a reminder is for are exactly the ones
-- with no header. Hence an employee-keyed sibling.
--
-- To avoid two homes for one fact, the day arithmetic moves into a primitive
-- that takes the schedule and the calendar as arguments, and the employee-keyed
-- function resolves those and calls it.
--
-- DEBT, recorded deliberately: time_planned_minutes_for_date() is NOT folded
-- onto the primitive here. It sits on the timesheet-entry validation trigger
-- path, it reads the header's OWN work_schedule_id snapshot rather than
-- employment's, and collapsing those two resolutions is a behaviour change that
-- deserves its own migration and its own equality proof over real headers.
-- Until then the arithmetic exists twice and the two must be changed together.
--
-- Decisions taken with Vj, 27 Sep 2026:
--   - offset 0 means the first working day ON OR AFTER period end. Pushed
--     forward, never back.
--   - every other offset is counted from the day 0 resolves to, so the rules
--     stay one working day apart whatever the holidays do.
--   - the DEADLINE stays calendar-based (856). Reminders and the overdue flag
--     may therefore disagree by a day or two; that was the cheaper trade, and
--     it keeps time_submission_due_date() a function of the period alone, which
--     is what lets the compliance report compute it three times instead of
--     thirty thousand.
--
-- Depends on : 696 (schedules), 710 (calendar entries), 837 (period end)
-- =============================================================================

BEGIN;

-- ── 1. The primitive: planned minutes for a schedule + calendar on a date ────

CREATE OR REPLACE FUNCTION public.time_planned_minutes_for_schedule(
  p_work_schedule_id uuid,
  p_calendar_id      uuid,
  p_date             date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT CASE
    -- No schedule is not "zero hours on Tuesday", it is "we do not know". Both
    -- answer 0 here; the caller that cares distinguishes them (the compliance
    -- report excludes these people from Expected rather than marking them late).
    WHEN p_work_schedule_id IS NULL THEN 0
    WHEN EXISTS (
      SELECT 1 FROM time_calendar_entries ce
      WHERE  ce.calendar_id = p_calendar_id
        AND  ce.entry_date  = p_date
    ) THEN 0
    ELSE COALESCE((
      SELECT l.planned_minutes
      FROM   time_work_schedules      ws
      JOIN   time_work_schedule_lines l
             ON  l.work_schedule_id = ws.id
             -- Same day_number derivation as 718/722. The schedule's own
             -- start_day_of_week decides which line a weekday maps to.
             AND l.day_number = ((EXTRACT(DOW FROM p_date)::int - ws.start_day_of_week + 7) % 7) + 1
      WHERE  ws.id = p_work_schedule_id), 0)
  END;
$fn$;

COMMENT ON FUNCTION public.time_planned_minutes_for_schedule(uuid, uuid, date) IS
  'Mig 857: planned minutes for a work schedule + holiday calendar on one date. '
  'The day arithmetic, with no opinion about whose day it is. Holiday wins over '
  'schedule. See the DEBT note in 857: time_planned_minutes_for_date() still '
  'carries its own copy and the two must change together.';


-- ── 2. Is this a working day for this employee ───────────────────────────────

CREATE OR REPLACE FUNCTION public.time_is_working_day(
  p_employee_id uuid,
  p_date        date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- COALESCE to false, not NULL: an employee with no current employment row has
  -- no working days, and a NULL here would make the WHILE loops below fall
  -- straight through and hand back period end as though it were a working day.
  SELECT COALESCE((
    SELECT time_planned_minutes_for_schedule(ee.work_schedule_id,
                                             ee.holiday_calendar_id,
                                             p_date) > 0
    FROM (
      SELECT x.work_schedule_id, x.holiday_calendar_id
      FROM   employee_employment x
      WHERE  x.employee_id = p_employee_id
        AND (x.effective_to IS NULL OR x.effective_to = DATE '9999-12-31')
      -- .order is not decoration: two open-ended rows and LIMIT 1 without it
      -- returns whichever the planner feels like. Same hazard mig 837 found.
      ORDER  BY x.effective_from DESC
      LIMIT  1
    ) ee
  ), false);
$fn$;

COMMENT ON FUNCTION public.time_is_working_day(uuid, date) IS
  'Mig 857: does this employee work on this date, per their own schedule and '
  'holiday calendar. False when they have no schedule or no employment row.';


-- ── 3. The date a reminder rule fires for one employee ───────────────────────

CREATE OR REPLACE FUNCTION public.time_reminder_fire_date(
  p_employee_id uuid,
  p_period      date,
  p_offset      integer)
RETURNS date
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_day   date;
  v_step  integer;
  v_left  integer;
  v_guard integer := 0;
BEGIN
  IF p_employee_id IS NULL OR p_period IS NULL OR p_offset IS NULL THEN
    RETURN NULL;
  END IF;

  v_day  := timesheet_period_end(p_period);
  v_step := CASE WHEN p_offset < 0 THEN -1 ELSE 1 END;
  v_left := abs(p_offset);

  -- Offset 0 is "the last day of the timesheet". When that day is not a working
  -- one it is pushed FORWARD. Pulling it back would send "due today" while the
  -- period is still open and the employee can still add to it.
  WHILE NOT time_is_working_day(p_employee_id, v_day) LOOP
    v_guard := v_guard + 1;
    -- An all-zero schedule has no working days and this would spin forever.
    -- NULL is the honest answer: there is no such day. Callers skip them.
    IF v_guard > 120 THEN RETURN NULL; END IF;
    v_day := v_day + 1;
  END LOOP;

  -- Everything else is counted from wherever 0 landed, so the rules stay one
  -- working day apart however many holidays fall between them.
  WHILE v_left > 0 LOOP
    v_day   := v_day + v_step;
    v_guard := v_guard + 1;
    IF v_guard > 400 THEN RETURN NULL; END IF;
    IF time_is_working_day(p_employee_id, v_day) THEN
      v_left := v_left - 1;
    END IF;
  END LOOP;

  RETURN v_day;
END
$fn$;

COMMENT ON FUNCTION public.time_reminder_fire_date(uuid, date, integer) IS
  'Mig 857: the date a reminder rule with this offset fires for this employee, '
  'counted in THEIR working days from THEIR period end. Offset 0 = first '
  'working day on or after period end; positive counts forward from there; '
  'negative counts back. NULL when the employee has no working days at all.';


-- ── 4. Grants ────────────────────────────────────────────────────────────────

REVOKE ALL ON FUNCTION public.time_planned_minutes_for_schedule(uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.time_is_working_day(uuid, date)                     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.time_reminder_fire_date(uuid, date, integer)        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_planned_minutes_for_schedule(uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.time_is_working_day(uuid, date)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.time_reminder_fire_date(uuid, date, integer)        TO authenticated;


-- ── 5. Verification — invariants, on whatever data this database holds ───────

DO $mig$
DECLARE
  v_period  date := timesheet_period_of(CURRENT_DATE);
  r         record;
  v_checked integer := 0;
  v_d0 date; v_d1 date; v_d2 date;
BEGIN
  FOR r IN
    SELECT e.id
    FROM   employees e
    JOIN   employee_employment ee ON ee.employee_id = e.id
                                 AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
    WHERE  e.deleted_at IS NULL
      AND  e.status = 'Active'
      AND  ee.work_schedule_id IS NOT NULL
    LIMIT  25
  LOOP
    v_d0 := time_reminder_fire_date(r.id, v_period, 0);
    v_d1 := time_reminder_fire_date(r.id, v_period, 1);
    v_d2 := time_reminder_fire_date(r.id, v_period, 2);

    CONTINUE WHEN v_d0 IS NULL;   -- schedule with no working days at all

    IF NOT time_is_working_day(r.id, v_d0) THEN
      RAISE EXCEPTION 'MIG 857: offset 0 resolved to %, not a working day, for employee %.', v_d0, r.id;
    END IF;
    IF v_d0 < timesheet_period_end(v_period) THEN
      RAISE EXCEPTION 'MIG 857: offset 0 resolved to % which is BEFORE period end % -- it must push forward.',
        v_d0, timesheet_period_end(v_period);
    END IF;
    IF NOT (v_d2 > v_d1 AND v_d1 > v_d0) THEN
      RAISE EXCEPTION 'MIG 857: offsets out of order for employee %: 0=%, 1=%, 2=%.', r.id, v_d0, v_d1, v_d2;
    END IF;
    v_checked := v_checked + 1;
  END LOOP;

  RAISE NOTICE 'MIG 857: invariants hold for % employees (period %, ends %).',
    v_checked, v_period, timesheet_period_end(v_period);
END
$mig$;

COMMIT;
