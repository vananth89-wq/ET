-- =============================================================================
-- Migration 701 — Backfill NULL work_schedule_id + holiday_calendar_id +
--                 planned_minutes on existing timesheet_headers
--
-- BUG
-- ═══
-- MyTimesheet's header-creation path queried employee_employment with
-- `.is('effective_to', null)`, but the effective-dating pattern uses
-- '9999-12-31' as the open-ended sentinel — so the query returned no row.
-- Result: headers were created with work_schedule_id = NULL,
-- holiday_calendar_id = NULL, planned_minutes = 0. On the UI every day
-- rendered as "Non-working".
--
-- The frontend query is now fixed (uses effective_to = '9999-12-31'),
-- so future headers will be correct. This migration backfills any header
-- already created with NULL schedule, pulling the correct schedule +
-- calendar from the current employment row, and recomputing planned_minutes
-- for the period.
--
-- Idempotent: only touches headers that still have NULL work_schedule_id.
-- Skips headers whose employee has no current employment (data anomaly).
-- =============================================================================

DO $$
DECLARE
  v_header       RECORD;
  v_emp          RECORD;
  v_planned      int;
BEGIN
  FOR v_header IN
    SELECT id, employee_id, period
    FROM   public.timesheet_headers
    WHERE  work_schedule_id IS NULL
  LOOP
    -- Pull current employment (the open-ended slice)
    SELECT work_schedule_id, holiday_calendar_id
    INTO   v_emp
    FROM   public.employee_employment
    WHERE  employee_id = v_header.employee_id
      AND  is_active   = true
      AND  effective_to = '9999-12-31'::date
    LIMIT  1;

    IF NOT FOUND OR v_emp.work_schedule_id IS NULL THEN
      RAISE NOTICE 'Migration 701: skipping header % — no employment/schedule for employee %',
                   v_header.id, v_header.employee_id;
      CONTINUE;
    END IF;

    -- Recompute planned_minutes for the header's period
    SELECT COALESCE(SUM(COALESCE(l.planned_minutes, 0)), 0)::int
    INTO   v_planned
    FROM   generate_series(
             v_header.period,
             (v_header.period + interval '1 month' - interval '1 day')::date,
             interval '1 day'
           ) d(day)
    LEFT JOIN public.time_work_schedule_lines l
           ON l.work_schedule_id = v_emp.work_schedule_id
          AND l.day_number       = EXTRACT(DOW FROM d.day)::int + 1
    WHERE  NOT EXISTS (
      SELECT 1
      FROM   public.time_holidays h
      WHERE  h.calendar_id  = v_emp.holiday_calendar_id
        AND  h.holiday_date = d.day::date
    );

    UPDATE public.timesheet_headers
    SET    work_schedule_id    = v_emp.work_schedule_id,
           holiday_calendar_id = v_emp.holiday_calendar_id,
           planned_minutes     = v_planned,
           updated_at          = now()
    WHERE  id = v_header.id;

    RAISE NOTICE 'Migration 701: backfilled header % (period %) — schedule %, planned %min',
                 v_header.id, v_header.period, v_emp.work_schedule_id, v_planned;
  END LOOP;
END $$;
