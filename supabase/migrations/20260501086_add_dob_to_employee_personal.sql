-- =============================================================================
-- Migration : 20260501086_add_dob_to_employee_personal.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description: Adds dob (date of birth) DATE column to employee_personal.
--              Age is always derived at runtime — not stored.
--              Idempotent via IF NOT EXISTS guard.
-- =============================================================================

ALTER TABLE employee_personal
  ADD COLUMN IF NOT EXISTS dob DATE;

COMMENT ON COLUMN employee_personal.dob IS
  'Date of birth. Age is calculated at runtime from this value — never stored separately.';

-- =============================================================================
-- END OF MIGRATION 20260501086_add_dob_to_employee_personal.sql
-- =============================================================================
