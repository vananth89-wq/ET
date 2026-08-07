-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 723: correct 722's snapshot precedence, and recompute planned
--                minutes when a work schedule or an assignment changes.
--
-- ── PART A: fixing a regression in 722 ────────────────────────────────────
-- Mig 718 stated the design intent plainly:
--
--     "Uses the header's snapshotted schedule + calendar, not the employee's
--      current employment, so historical months stay correct."
--
-- With no effective dating on time_work_schedules, that snapshot IS the
-- effective dating. 722 inverted it — COALESCE(employment, header) — so current
-- employment won even when the header held a perfectly good historical value.
-- Transfer someone from the India calendar to UAE and every closed month would
-- retroactively recompute against UAE holidays.
--
-- The bug 722 was chasing was a NULL snapshot, not a wrong one. Correct
-- precedence is therefore the other way round:
--
--     COALESCE(header_snapshot, current_employment)
--
-- Snapshot wins when it exists; employment fills the gap when it does not.
-- 722's backfill is likewise narrowed to NULL snapshots only, so a legitimate
-- historical assignment is never overwritten.
--
-- 722's backfill overwrote snapshots that merely DIFFERED from employment.
-- Those prior values are unrecoverable — there is no audit trigger on
-- timesheet_headers. On an environment where 722 ran against real transfer
-- history, verify affected headers by hand before trusting their totals.
--
-- ── PART B: the new triggers ──────────────────────────────────────────────
-- 722 covers holiday calendar edits. Two adjacent changes were left uncovered:
--   * editing a work schedule's lines (Friday becomes a working day)
--   * reassigning an employee's schedule or calendar on their employment row
--
-- Both are bounded to the CURRENT MONTH FORWARD. A schedule edit is a
-- redefinition, not a correction of the past: months already worked were
-- planned under the old definition and must keep it. This differs from 722's
-- holiday trigger, which is unbounded because a holiday edit names one specific
-- month and is therefore self-scoping.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Correct the precedence, and cover work_schedule_id the same way ─────
CREATE OR REPLACE FUNCTION public.time_planned_minutes_for_date(p_header_id uuid, p_date date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ctx AS (
    SELECT
      -- Snapshot first. Employment is a fallback for headers created before the
      -- assignment existed, never an override of a recorded historical value.
      COALESCE(h.work_schedule_id, (
        SELECT ee.work_schedule_id FROM employee_employment ee
         WHERE ee.employee_id = h.employee_id
           AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
           AND ee.work_schedule_id IS NOT NULL
         LIMIT 1)) AS work_schedule_id,
      COALESCE(h.holiday_calendar_id, (
        SELECT ee.holiday_calendar_id FROM employee_employment ee
         WHERE ee.employee_id = h.employee_id
           AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
           AND ee.holiday_calendar_id IS NOT NULL
         LIMIT 1)) AS calendar_id
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
  'Mig 723: planned minutes for a single date. Holidays return 0. Schedule and '
  'calendar come from the header snapshot, falling back to current employment '
  'only when the snapshot is NULL, so historical months keep their own basis.';

-- ── 2. Fill NULL snapshots only — never overwrite a recorded one ───────────
DO $$
DECLARE v_cal integer; v_ws integer;
BEGIN
  UPDATE timesheet_headers h
     SET holiday_calendar_id = ee.holiday_calendar_id
    FROM employee_employment ee
   WHERE ee.employee_id = h.employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
     AND ee.holiday_calendar_id IS NOT NULL
     AND h.holiday_calendar_id IS NULL;          -- NULL only, unlike mig 722
  GET DIAGNOSTICS v_cal = ROW_COUNT;

  UPDATE timesheet_headers h
     SET work_schedule_id = ee.work_schedule_id
    FROM employee_employment ee
   WHERE ee.employee_id = h.employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
     AND ee.work_schedule_id IS NOT NULL
     AND h.work_schedule_id IS NULL;
  GET DIAGNOSTICS v_ws = ROW_COUNT;

  RAISE NOTICE 'Migration 723: filled % NULL calendar and % NULL schedule snapshot(s).',
               v_cal, v_ws;
END $$;

-- ── 3. One place where the recompute policy lives ──────────────────────────
-- Extracted from 722's time_holiday_calendar_changed so the holiday trigger and
-- the two new triggers cannot drift apart on what happens to each status.
CREATE OR REPLACE FUNCTION public.time_apply_planned_recalc(
  p_header_id uuid,
  p_reason    text,
  p_context   jsonb DEFAULT '{}'::jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r     record;
  v_new integer;
BEGIN
  SELECT id, employee_id, status, planned_minutes, submitted_at
    INTO r
    FROM timesheet_headers WHERE id = p_header_id;
  IF r.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_new := time_recalc_planned_minutes(p_header_id);
  IF v_new IS NOT DISTINCT FROM r.planned_minutes THEN
    RETURN v_new;                       -- nothing moved, nothing to say
  END IF;

  IF r.status = 'approved' THEN
    -- planned is a denominator, not the decision. Recompute it, leave the
    -- approval alone, and record the shift in both directions.
    INSERT INTO employee_audit_log
      (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
    VALUES
      ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
       jsonb_build_object('status', r.status, 'planned_minutes', r.planned_minutes),
       jsonb_build_object('status', r.status, 'planned_minutes', v_new,
                          'reason', p_reason || '_after_approval',
                          'action', 'planned recomputed; approval left intact')
         || p_context,
       auth.uid());
    RETURN v_new;
  END IF;

  IF r.status = 'to_be_approved' THEN
    UPDATE timesheet_headers
       SET status = 'to_be_submitted', submitted_at = NULL
     WHERE id = r.id;

    INSERT INTO employee_audit_log
      (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
    VALUES
      ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
       jsonb_build_object('status', r.status, 'submitted_at', r.submitted_at,
                          'planned_minutes', r.planned_minutes),
       jsonb_build_object('status', 'to_be_submitted', 'submitted_at', NULL,
                          'planned_minutes', v_new, 'reason', p_reason)
         || p_context,
       auth.uid());
  END IF;

  RETURN v_new;
END;
$$;

REVOKE ALL ON FUNCTION public.time_apply_planned_recalc(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_apply_planned_recalc(uuid, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.time_apply_planned_recalc IS
  'Mig 723: recompute one header and apply the status policy — approved keeps '
  'its stamp, to_be_approved returns to the employee. Audited when it moves.';

-- ── 4. Route 722''s holiday trigger through the same policy ────────────────
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
  v_touched integer := 0;
BEGIN
  IF p_calendar_id IS NULL OR p_period IS NULL THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT h.id
      FROM timesheet_headers h
     WHERE h.period = p_period
       AND COALESCE(h.holiday_calendar_id, (
             SELECT ee.holiday_calendar_id FROM employee_employment ee
              WHERE ee.employee_id = h.employee_id
                AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                AND ee.holiday_calendar_id IS NOT NULL
              LIMIT 1)) = p_calendar_id
  LOOP
    PERFORM time_apply_planned_recalc(
      r.id, 'holiday_calendar_changed',
      jsonb_build_object('calendar_id', p_calendar_id, 'period', p_period));
    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_holiday_calendar_changed(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_holiday_calendar_changed(uuid, date) TO authenticated;

-- ── 5. A work schedule definition changed ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.time_work_schedule_changed(p_schedule_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r         record;
  v_floor   date := DATE_TRUNC('month', CURRENT_DATE)::date;
  v_touched integer := 0;
BEGIN
  IF p_schedule_id IS NULL THEN
    RETURN 0;
  END IF;

  -- Current month forward only. Editing a schedule redefines how time is
  -- planned from now on; it does not retroactively re-plan months that were
  -- already worked under the previous definition.
  FOR r IN
    SELECT h.id FROM timesheet_headers h
     WHERE h.period >= v_floor
       AND COALESCE(h.work_schedule_id, (
             SELECT ee.work_schedule_id FROM employee_employment ee
              WHERE ee.employee_id = h.employee_id
                AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                AND ee.work_schedule_id IS NOT NULL
              LIMIT 1)) = p_schedule_id
  LOOP
    PERFORM time_apply_planned_recalc(
      r.id, 'work_schedule_changed',
      jsonb_build_object('work_schedule_id', p_schedule_id));
    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_work_schedule_changed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_work_schedule_changed(uuid) TO authenticated;
COMMENT ON FUNCTION public.time_work_schedule_changed IS
  'Mig 723: recompute planned_minutes for open headers on a schedule whose '
  'definition changed. Current month forward only — history keeps its basis.';

-- ── 6. An employee was reassigned ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.time_employment_assignment_changed(p_employee_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r         record;
  v_floor   date := DATE_TRUNC('month', CURRENT_DATE)::date;
  v_ws      uuid;
  v_cal     uuid;
  v_touched integer := 0;
BEGIN
  SELECT ee.work_schedule_id, ee.holiday_calendar_id INTO v_ws, v_cal
    FROM employee_employment ee
   WHERE ee.employee_id = p_employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
   LIMIT 1;

  -- Move the snapshot forward on open periods only, so closed months keep the
  -- assignment they were actually worked under.
  FOR r IN
    SELECT id FROM timesheet_headers
     WHERE employee_id = p_employee_id
       AND period >= v_floor
  LOOP
    UPDATE timesheet_headers
       SET work_schedule_id    = COALESCE(v_ws,  work_schedule_id),
           holiday_calendar_id = COALESCE(v_cal, holiday_calendar_id)
     WHERE id = r.id;

    PERFORM time_apply_planned_recalc(
      r.id, 'employment_assignment_changed',
      jsonb_build_object('work_schedule_id', v_ws, 'holiday_calendar_id', v_cal));
    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_employment_assignment_changed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_employment_assignment_changed(uuid) TO authenticated;
COMMENT ON FUNCTION public.time_employment_assignment_changed IS
  'Mig 723: re-point open headers at an employee''s current schedule/calendar '
  'and recompute. Current month forward only.';

-- ── 7. Wire the triggers ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_time_schedule_lines_recalc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM time_work_schedule_changed(NEW.work_schedule_id);
  END IF;
  IF TG_OP = 'DELETE'
     OR (TG_OP = 'UPDATE' AND OLD.work_schedule_id <> NEW.work_schedule_id) THEN
    PERFORM time_work_schedule_changed(OLD.work_schedule_id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_schedule_lines_recalc ON time_work_schedule_lines;
CREATE TRIGGER trg_time_schedule_lines_recalc
  AFTER INSERT OR UPDATE OR DELETE ON time_work_schedule_lines
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_schedule_lines_recalc();

-- start_day_of_week rotates which weekday each line maps to, so it changes
-- planned minutes just as much as editing the lines themselves.
CREATE OR REPLACE FUNCTION public.trg_time_work_schedules_recalc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.start_day_of_week IS DISTINCT FROM OLD.start_day_of_week THEN
    PERFORM time_work_schedule_changed(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_work_schedules_recalc ON time_work_schedules;
CREATE TRIGGER trg_time_work_schedules_recalc
  AFTER UPDATE ON time_work_schedules
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_work_schedules_recalc();

CREATE OR REPLACE FUNCTION public.trg_employment_assignment_recalc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only the currently-effective row drives open timesheets. Historical rows
  -- being closed off by the effective-dating sync must not trigger a recompute.
  IF NEW.effective_to IS NULL OR NEW.effective_to = DATE '9999-12-31' THEN
    PERFORM time_employment_assignment_changed(NEW.employee_id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_assignment_recalc ON employee_employment;
CREATE TRIGGER trg_employment_assignment_recalc
  AFTER UPDATE OF work_schedule_id, holiday_calendar_id ON employee_employment
  FOR EACH ROW
  WHEN (OLD.work_schedule_id    IS DISTINCT FROM NEW.work_schedule_id
     OR OLD.holiday_calendar_id IS DISTINCT FROM NEW.holiday_calendar_id)
  EXECUTE FUNCTION public.trg_employment_assignment_recalc();

-- ── 8. Re-repair the 6-month window under the corrected precedence ─────────
DO $$
DECLARE
  r       record;
  v_after integer;
  v_fixed integer := 0;
  v_seen  integer := 0;
  v_floor date := (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months')::date;
BEGIN
  FOR r IN
    SELECT id, planned_minutes FROM timesheet_headers WHERE period >= v_floor
  LOOP
    v_seen  := v_seen + 1;
    v_after := time_recalc_planned_minutes(r.id);
    IF v_after IS DISTINCT FROM r.planned_minutes THEN
      v_fixed := v_fixed + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Migration 723: scanned % header(s) since %, corrected %.',
               v_seen, v_floor, v_fixed;
END $$;

-- ── 9. Verify ──────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['trg_time_schedule_lines_recalc',
                           'trg_time_work_schedules_recalc',
                           'trg_employment_assignment_recalc',
                           'trg_time_holidays_recalc'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t AND NOT tgisinternal) THEN
      RAISE EXCEPTION 'ABORT: trigger % not found.', t;
    END IF;
  END LOOP;

  FOREACH t IN ARRAY ARRAY['time_apply_planned_recalc',
                           'time_work_schedule_changed',
                           'time_employment_assignment_changed'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = t) THEN
      RAISE EXCEPTION 'ABORT: function %() not created.', t;
    END IF;
  END LOOP;

  -- Precedence guard: a header carrying its own snapshot must NOT be resolved
  -- through employment. Fails loudly if someone reinstates 722's ordering.
  IF EXISTS (
    SELECT 1
      FROM pg_proc
     WHERE proname = 'time_planned_minutes_for_date'
       AND prosrc LIKE '%COALESCE(%ee.holiday_calendar_id%h.holiday_calendar_id%'
  ) THEN
    RAISE EXCEPTION 'ABORT: time_planned_minutes_for_date still prefers employment over the header snapshot.';
  END IF;

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

  RAISE NOTICE 'Migration 723 verified: snapshot precedence restored, schedule '
               'and assignment changes now recompute open periods.';
END $$;
