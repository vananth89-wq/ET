-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 724: point the timesheet at the RIGHT holiday table.
--
-- ROOT CAUSE — the one that made every earlier fix pointless.
--
-- Migration 709 split holidays into two tables:
--     time_holidays          = GLOBAL POOL of definitions.
--                              709 DROPPED its calendar_id column.
--     time_calendar_entries  = the calendar × date rows (mig 710)
--                              (calendar_id, entry_date, holiday_id)
--
-- Everything written afterwards kept querying the OLD shape —
-- `time_holidays WHERE calendar_id = … AND holiday_date = …` — against a table
-- that no longer has calendar_id. Affected:
--
--   * time_planned_minutes_for_date()   (mig 718, edited by 722 and 723)
--   * time_holiday_calendar_changed()   (mig 722, edited by 723)
--   * trg_time_holidays_recalc          (mig 722) — bound to the POOL table, so
--                                       editing a calendar never fired it
--   * MyTimesheet loadPeriod            (fixed separately in the frontend)
--
-- The frontend swallowed the error (`const { data } = …`, no error check), so a
-- 400 looked exactly like "this calendar has no holidays this month". The
-- symptom was the holiday never appearing and planned_minutes never moving off
-- 176 hr, through three rounds of fixes that were all downstream of this.
--
-- SELF-CONTAINED BY DESIGN. If 718/722/723 aborted on the missing column, their
-- functions do not exist at all. This migration recreates the whole
-- planned-minutes stack rather than assuming any of it is in place, and reports
-- what it found. Safe to run whether they applied, half-applied, or failed.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0. What state are we actually in? ──────────────────────────────────────
DO $$
DECLARE v_missing text := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_name = 'time_calendar_entries' AND column_name = 'entry_date') THEN
    RAISE EXCEPTION 'ABORT: time_calendar_entries.entry_date not found — migration 710 has not been applied.';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_name = 'time_holidays' AND column_name = 'calendar_id') THEN
    RAISE NOTICE 'Migration 724: time_holidays STILL has calendar_id — mig 709 did not apply here. The old functions may have worked; they are being repointed anyway.';
  END IF;

  FOR v_missing IN
    SELECT f FROM unnest(ARRAY['time_planned_minutes_for_date','time_recalc_planned_minutes',
                               'time_apply_planned_recalc','time_holiday_calendar_changed',
                               'time_work_schedule_changed','time_employment_assignment_changed']) f
     WHERE NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = f)
  LOOP
    RAISE NOTICE 'Migration 724: %() was MISSING — an earlier migration did not complete.', v_missing;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'enforce_timesheet_entry_rules') THEN
    RAISE WARNING 'Migration 724: enforce_timesheet_entry_rules() is missing — migs 718/721 did not apply. Half-day and mandatory-activity rules are NOT enforced. Re-run those separately.';
  END IF;
END $$;

-- ── 1. Planned minutes for one date, from the correct table ────────────────
-- Precedence per mig 723: header snapshot wins, employment fills a NULL only.
CREATE OR REPLACE FUNCTION public.time_planned_minutes_for_date(p_header_id uuid, p_date date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ctx AS (
    SELECT
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
      SELECT 1 FROM time_calendar_entries ce, ctx
       WHERE ce.calendar_id = ctx.calendar_id
         AND ce.entry_date  = p_date
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
  'Mig 724: planned minutes for one date. Holidays (time_calendar_entries) return 0. '
  'Schedule/calendar from the header snapshot, employment only as a NULL fallback.';

-- ── 2. Recompute one header ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.time_recalc_planned_minutes(p_header_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_period date; v_total integer;
BEGIN
  SELECT period INTO v_period FROM timesheet_headers WHERE id = p_header_id;
  IF v_period IS NULL THEN RETURN NULL; END IF;

  SELECT COALESCE(SUM(time_planned_minutes_for_date(p_header_id, d::date)), 0)
    INTO v_total
    FROM generate_series(v_period,
                         (v_period + INTERVAL '1 month' - INTERVAL '1 day')::date,
                         INTERVAL '1 day') AS d;

  UPDATE timesheet_headers SET planned_minutes = v_total
   WHERE id = p_header_id AND planned_minutes IS DISTINCT FROM v_total;

  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.time_recalc_planned_minutes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_recalc_planned_minutes(uuid) TO authenticated;

-- ── 3. The status policy, in one place ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.time_apply_planned_recalc(
  p_header_id uuid, p_reason text, p_context jsonb DEFAULT '{}'::jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r record; v_new integer;
BEGIN
  SELECT id, employee_id, status, planned_minutes, submitted_at INTO r
    FROM timesheet_headers WHERE id = p_header_id;
  IF r.id IS NULL THEN RETURN NULL; END IF;

  v_new := time_recalc_planned_minutes(p_header_id);
  IF v_new IS NOT DISTINCT FROM r.planned_minutes THEN RETURN v_new; END IF;

  IF r.status = 'approved' THEN
    INSERT INTO employee_audit_log
      (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
    VALUES ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
      jsonb_build_object('status', r.status, 'planned_minutes', r.planned_minutes),
      jsonb_build_object('status', r.status, 'planned_minutes', v_new,
                         'reason', p_reason || '_after_approval',
                         'action', 'planned recomputed; approval left intact') || p_context,
      auth.uid());
    RETURN v_new;
  END IF;

  IF r.status = 'to_be_approved' THEN
    UPDATE timesheet_headers SET status = 'to_be_submitted', submitted_at = NULL WHERE id = r.id;
    INSERT INTO employee_audit_log
      (table_name, record_id, employee_id, operation, old_data, new_data, changed_by)
    VALUES ('timesheet_headers', r.id, r.employee_id, 'UPDATE',
      jsonb_build_object('status', r.status, 'submitted_at', r.submitted_at,
                         'planned_minutes', r.planned_minutes),
      jsonb_build_object('status', 'to_be_submitted', 'submitted_at', NULL,
                         'planned_minutes', v_new, 'reason', p_reason) || p_context,
      auth.uid());
  END IF;

  RETURN v_new;
END;
$$;

REVOKE ALL ON FUNCTION public.time_apply_planned_recalc(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_apply_planned_recalc(uuid, text, jsonb) TO authenticated;

-- ── 4. Calendar changed — now keyed on time_calendar_entries ───────────────
CREATE OR REPLACE FUNCTION public.time_holiday_calendar_changed(
  p_calendar_id uuid, p_period date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r record; v_touched integer := 0;
BEGIN
  IF p_calendar_id IS NULL OR p_period IS NULL THEN RETURN 0; END IF;

  FOR r IN
    SELECT h.id FROM timesheet_headers h
     WHERE h.period = p_period
       AND COALESCE(h.holiday_calendar_id, (
             SELECT ee.holiday_calendar_id FROM employee_employment ee
              WHERE ee.employee_id = h.employee_id
                AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
                AND ee.holiday_calendar_id IS NOT NULL
              LIMIT 1)) = p_calendar_id
  LOOP
    PERFORM time_apply_planned_recalc(r.id, 'holiday_calendar_changed',
      jsonb_build_object('calendar_id', p_calendar_id, 'period', p_period));
    v_touched := v_touched + 1;
  END LOOP;

  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_holiday_calendar_changed(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_holiday_calendar_changed(uuid, date) TO authenticated;

-- ── 5. Schedule + assignment handlers (current month forward) ──────────────
CREATE OR REPLACE FUNCTION public.time_work_schedule_changed(p_schedule_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r record; v_floor date := DATE_TRUNC('month', CURRENT_DATE)::date; v_touched integer := 0;
BEGIN
  IF p_schedule_id IS NULL THEN RETURN 0; END IF;
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
    PERFORM time_apply_planned_recalc(r.id, 'work_schedule_changed',
      jsonb_build_object('work_schedule_id', p_schedule_id));
    v_touched := v_touched + 1;
  END LOOP;
  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_work_schedule_changed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_work_schedule_changed(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.time_employment_assignment_changed(p_employee_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r record; v_floor date := DATE_TRUNC('month', CURRENT_DATE)::date;
        v_ws uuid; v_cal uuid; v_touched integer := 0;
BEGIN
  SELECT ee.work_schedule_id, ee.holiday_calendar_id INTO v_ws, v_cal
    FROM employee_employment ee
   WHERE ee.employee_id = p_employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
   LIMIT 1;

  FOR r IN
    SELECT id FROM timesheet_headers
     WHERE employee_id = p_employee_id AND period >= v_floor
  LOOP
    UPDATE timesheet_headers
       SET work_schedule_id    = COALESCE(v_ws,  work_schedule_id),
           holiday_calendar_id = COALESCE(v_cal, holiday_calendar_id)
     WHERE id = r.id;
    PERFORM time_apply_planned_recalc(r.id, 'employment_assignment_changed',
      jsonb_build_object('work_schedule_id', v_ws, 'holiday_calendar_id', v_cal));
    v_touched := v_touched + 1;
  END LOOP;
  RETURN v_touched;
END;
$$;

REVOKE ALL ON FUNCTION public.time_employment_assignment_changed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_employment_assignment_changed(uuid) TO authenticated;

-- ── 6. Move the holiday trigger onto the table that actually changes ───────
-- 722 bound it to time_holidays, the global POOL. Adding a date to a calendar
-- touches time_calendar_entries, so the trigger could never have fired.
DROP TRIGGER IF EXISTS trg_time_holidays_recalc ON time_holidays;
-- CORRECTED 2026-08-09: mig 722 attaches this trigger to time_calendar_entries
-- (722 line 277), not to the time_holidays pool -- the header above assumed the
-- pool. Dropping only the pool binding left the function with a live dependent,
-- so DROP FUNCTION failed with "other objects depend on it" on any database
-- where 722 had actually run. Dev happened not to be in that state; a clean
-- replay always is. Both bindings are removed here, and the correct trigger is
-- recreated as trg_time_calendar_entries_recalc further down.
DROP TRIGGER IF EXISTS trg_time_holidays_recalc ON time_calendar_entries;
DROP FUNCTION IF EXISTS public.trg_time_holidays_recalc();

CREATE OR REPLACE FUNCTION public.trg_time_calendar_entries_recalc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM time_holiday_calendar_changed(
      NEW.calendar_id, date_trunc('month', NEW.entry_date)::date);
  END IF;
  -- Old location too, so moving a date across months restores the one it left.
  IF TG_OP = 'DELETE'
     OR (TG_OP = 'UPDATE'
         AND (OLD.entry_date <> NEW.entry_date OR OLD.calendar_id <> NEW.calendar_id)) THEN
    PERFORM time_holiday_calendar_changed(
      OLD.calendar_id, date_trunc('month', OLD.entry_date)::date);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_calendar_entries_recalc ON time_calendar_entries;
CREATE TRIGGER trg_time_calendar_entries_recalc
  AFTER INSERT OR UPDATE OR DELETE ON time_calendar_entries
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_calendar_entries_recalc();

-- ── 7. Schedule + employment triggers (recreated; 723 may not have applied) ─
CREATE OR REPLACE FUNCTION public.trg_time_schedule_lines_recalc()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') THEN PERFORM time_work_schedule_changed(NEW.work_schedule_id); END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.work_schedule_id <> NEW.work_schedule_id) THEN
    PERFORM time_work_schedule_changed(OLD.work_schedule_id);
  END IF;
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_time_schedule_lines_recalc ON time_work_schedule_lines;
CREATE TRIGGER trg_time_schedule_lines_recalc
  AFTER INSERT OR UPDATE OR DELETE ON time_work_schedule_lines
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_schedule_lines_recalc();

CREATE OR REPLACE FUNCTION public.trg_time_work_schedules_recalc()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.start_day_of_week IS DISTINCT FROM OLD.start_day_of_week THEN
    PERFORM time_work_schedule_changed(NEW.id);
  END IF;
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_time_work_schedules_recalc ON time_work_schedules;
CREATE TRIGGER trg_time_work_schedules_recalc
  AFTER UPDATE ON time_work_schedules
  FOR EACH ROW EXECUTE FUNCTION public.trg_time_work_schedules_recalc();

CREATE OR REPLACE FUNCTION public.trg_employment_assignment_recalc()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.effective_to IS NULL OR NEW.effective_to = DATE '9999-12-31' THEN
    PERFORM time_employment_assignment_changed(NEW.employee_id);
  END IF;
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_employment_assignment_recalc ON employee_employment;
CREATE TRIGGER trg_employment_assignment_recalc
  AFTER UPDATE OF work_schedule_id, holiday_calendar_id ON employee_employment
  FOR EACH ROW
  WHEN (OLD.work_schedule_id    IS DISTINCT FROM NEW.work_schedule_id
     OR OLD.holiday_calendar_id IS DISTINCT FROM NEW.holiday_calendar_id)
  EXECUTE FUNCTION public.trg_employment_assignment_recalc();

-- ── 8. Fill NULL snapshots, then repair the last 6 months ──────────────────
DO $$
DECLARE v_cal integer; v_ws integer;
BEGIN
  UPDATE timesheet_headers h SET holiday_calendar_id = ee.holiday_calendar_id
    FROM employee_employment ee
   WHERE ee.employee_id = h.employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
     AND ee.holiday_calendar_id IS NOT NULL AND h.holiday_calendar_id IS NULL;
  GET DIAGNOSTICS v_cal = ROW_COUNT;

  UPDATE timesheet_headers h SET work_schedule_id = ee.work_schedule_id
    FROM employee_employment ee
   WHERE ee.employee_id = h.employee_id
     AND (ee.effective_to IS NULL OR ee.effective_to = DATE '9999-12-31')
     AND ee.work_schedule_id IS NOT NULL AND h.work_schedule_id IS NULL;
  GET DIAGNOSTICS v_ws = ROW_COUNT;

  RAISE NOTICE 'Migration 724: filled % NULL calendar and % NULL schedule snapshot(s).', v_cal, v_ws;
END $$;

DO $$
DECLARE r record; v_after integer; v_fixed integer := 0; v_seen integer := 0;
        v_floor date := (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months')::date;
BEGIN
  FOR r IN SELECT id, planned_minutes FROM timesheet_headers WHERE period >= v_floor LOOP
    v_seen := v_seen + 1;
    v_after := time_recalc_planned_minutes(r.id);
    IF v_after IS DISTINCT FROM r.planned_minutes THEN v_fixed := v_fixed + 1; END IF;
  END LOOP;
  RAISE NOTICE 'Migration 724: scanned % header(s) since %, corrected %.', v_seen, v_floor, v_fixed;
END $$;

-- ── 9. Verify ──────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  -- Nothing may still read calendar_id off the pool table.
  IF EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname IN ('time_planned_minutes_for_date','time_holiday_calendar_changed')
       AND prosrc LIKE '%time_holidays%calendar_id%'
  ) THEN
    RAISE EXCEPTION 'ABORT: a function still queries time_holidays.calendar_id.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgname = 'trg_time_holidays_recalc' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'ABORT: the old trigger on the holiday pool table still exists.';
  END IF;

  FOREACH t IN ARRAY ARRAY['trg_time_calendar_entries_recalc','trg_time_schedule_lines_recalc',
                           'trg_time_work_schedules_recalc','trg_employment_assignment_recalc'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t AND NOT tgisinternal) THEN
      RAISE EXCEPTION 'ABORT: trigger % not found.', t;
    END IF;
  END LOOP;

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

  RAISE NOTICE 'Migration 724 verified: holidays now read from time_calendar_entries.';
END $$;
