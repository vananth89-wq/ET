-- =============================================================================
-- Migration : 20260501085_add_gender_to_employee_personal.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-05-01
-- Description: Adds gender TEXT column to employee_personal satellite table.
--              Values: 'Male' | 'Female' (plain text, not picklist-backed).
--              Idempotent via IF NOT EXISTS guard.
-- =============================================================================

ALTER TABLE employee_personal
  ADD COLUMN IF NOT EXISTS gender TEXT;

COMMENT ON COLUMN employee_personal.gender IS
  'Employee gender. Plain text: ''Male'' or ''Female''.';

-- =============================================================================
-- END OF MIGRATION 20260501085_add_gender_to_employee_personal.sql
-- =============================================================================
