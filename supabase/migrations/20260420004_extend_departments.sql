-- =============================================================================
-- Migration : 20260420004_extend_departments.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Adds parent_dept_id, head_employee_id, start_date, end_date to
--              departments to match the Departments admin-UI data model.
--              All additions are idempotent (ADD COLUMN IF NOT EXISTS).
-- =============================================================================

ALTER TABLE departments
  ADD COLUMN IF NOT EXISTS parent_dept_id   UUID    REFERENCES departments(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS head_employee_id UUID    REFERENCES employees(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS start_date       DATE,
  ADD COLUMN IF NOT EXISTS end_date         DATE    DEFAULT '9999-12-31';

-- Backfill: departments that have no start_date get today as start_date
UPDATE departments
SET    start_date = CURRENT_DATE
WHERE  start_date IS NULL;

-- =============================================================================
-- END OF MIGRATION 20260420004_extend_departments.sql
-- =============================================================================
