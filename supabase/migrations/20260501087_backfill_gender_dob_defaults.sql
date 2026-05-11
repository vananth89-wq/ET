-- =============================================================================
-- Migration : 20260501087_backfill_gender_dob_defaults.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description:
--   1. Ensures every active employee has an employee_personal row.
--   2. Backfills gender  = 'Male'       where the column is NULL.
--   3. Backfills dob     = 1990-03-01   where the column is NULL.
--
--   These are placeholder defaults for pre-existing employees.
--   Both columns are now required on all new-hire / edit forms.
-- =============================================================================

-- Step 1: Insert stub employee_personal rows for employees that have none yet
INSERT INTO employee_personal (employee_id)
SELECT e.id
FROM   employees e
WHERE  e.deleted_at IS NULL
  AND  NOT EXISTS (
         SELECT 1 FROM employee_personal ep WHERE ep.employee_id = e.id
       )
ON CONFLICT (employee_id) DO NOTHING;

-- Step 2: Backfill gender where NULL
UPDATE employee_personal ep
SET    gender = 'Male'
FROM   employees e
WHERE  ep.employee_id = e.id
  AND  e.deleted_at   IS NULL
  AND  ep.gender      IS NULL;

-- Step 3: Backfill dob where NULL (placeholder: 1990-03-01)
UPDATE employee_personal ep
SET    dob = '1990-03-01'
FROM   employees e
WHERE  ep.employee_id = e.id
  AND  e.deleted_at   IS NULL
  AND  ep.dob         IS NULL;

-- =============================================================================
-- END OF MIGRATION 20260501087_backfill_gender_dob_defaults.sql
-- =============================================================================
