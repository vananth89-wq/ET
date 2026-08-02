-- =============================================================================
-- Migration 703 — Time Management: add scheduling columns to employee_employment
--
-- Adds:
--   work_schedule_id      — which schedule governs planned hours for this employee
--   holiday_calendar_id   — which holiday calendar applies to this employee
--
-- Both are nullable FKs; employees without assignments will simply show no
-- planned hours or auto-holidays on their timesheet until admin assigns them.
-- =============================================================================

ALTER TABLE employee_employment
  ADD COLUMN IF NOT EXISTS work_schedule_id    uuid REFERENCES time_work_schedules(id),
  ADD COLUMN IF NOT EXISTS holiday_calendar_id uuid REFERENCES time_holiday_calendars(id);

COMMENT ON COLUMN employee_employment.work_schedule_id    IS 'Mig 703: Assigned work schedule. Snapshotted onto timesheet_headers at creation time.';
COMMENT ON COLUMN employee_employment.holiday_calendar_id IS 'Mig 703: Assigned holiday calendar. Snapshotted onto timesheet_headers at creation time.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_emp_employment_work_schedule
  ON employee_employment (work_schedule_id)
  WHERE work_schedule_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_emp_employment_holiday_calendar
  ON employee_employment (holiday_calendar_id)
  WHERE holiday_calendar_id IS NOT NULL;

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'employee_employment'
      AND column_name  = 'work_schedule_id'
  ) THEN
    RAISE EXCEPTION 'ABORT: work_schedule_id column not found on employee_employment.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'employee_employment'
      AND column_name  = 'holiday_calendar_id'
  ) THEN
    RAISE EXCEPTION 'ABORT: holiday_calendar_id column not found on employee_employment.';
  END IF;
  RAISE NOTICE 'Migration 703 verified: work_schedule_id and holiday_calendar_id added to employee_employment.';
END $$;
