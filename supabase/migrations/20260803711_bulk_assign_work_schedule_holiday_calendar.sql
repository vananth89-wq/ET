-- Migration: 20260803711_bulk_assign_work_schedule_holiday_calendar
-- Assigns the "GEN" work schedule and "India" holiday calendar
-- to every employee whose current employment record has no effective_to
-- (i.e. their active/current employment row).
--
-- Safe to run multiple times — uses sub-selects to look up IDs by code/name
-- so it won't fail if they were already set.

DO $$
DECLARE
  v_schedule_id       uuid;
  v_calendar_id       uuid;
  v_rows_updated      integer;
BEGIN
  -- Resolve work schedule
  SELECT id INTO v_schedule_id
  FROM   time_work_schedules
  WHERE  code = 'GEN'
  LIMIT  1;

  IF v_schedule_id IS NULL THEN
    RAISE EXCEPTION 'Work schedule with code ''GEN'' not found. Create it first in Admin → Work Schedules.';
  END IF;

  -- Resolve holiday calendar
  SELECT id INTO v_calendar_id
  FROM   time_holiday_calendars
  WHERE  name = 'India'
  LIMIT  1;

  IF v_calendar_id IS NULL THEN
    RAISE EXCEPTION 'Holiday calendar named ''India'' not found. Create it first in Admin → Holiday Calendars.';
  END IF;

  -- Assign to all active employment rows (effective_to IS NULL)
  UPDATE employee_employment
  SET
    work_schedule_id    = v_schedule_id,
    holiday_calendar_id = v_calendar_id
  WHERE  effective_to IS NULL;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  RAISE NOTICE 'Assigned work_schedule_id=% (GEN) and holiday_calendar_id=% (India) to % employment record(s).',
    v_schedule_id, v_calendar_id, v_rows_updated;
END;
$$;
