-- =============================================================================
-- Migration 483 — Add notice_period_days to employee_employment
--
-- Design spec §2.4: notice_period_days is part of the bi-temporal employment
-- satellite. Termination RPCs read the slice where:
--   effective_from <= termination_date < effective_to
--
-- DEFAULT 30 covers all existing rows — no backfill needed.
-- Allowed values: 30, 90, 120 days (CHECK constraint).
--
-- Note on end_date / termination_reason_code column drops:
--   The design doc §2.4 also specifies removing end_date and
--   termination_reason_code from employee_employment. However:
--   • termination_reason_code does not exist on this table (column never added).
--   • end_date is actively used by 25+ employment RPC references (contract end
--     dates — a different concept from termination). Dropping it would break
--     upsert_employment_info, bulk_export, and all employment satellite reads.
--   These column removals are DEFERRED to a later cleanup migration once the
--   employment RPCs are updated to no longer reference end_date for
--   termination purposes. This migration adds only notice_period_days.
--
-- Predecessor: 20260604482 (termination schema)
-- Next migration: 20260604484 (picklists + permissions + module)
-- =============================================================================

ALTER TABLE employee_employment
  ADD COLUMN IF NOT EXISTS notice_period_days INTEGER NOT NULL DEFAULT 30
    CHECK (notice_period_days IN (30, 90, 120));

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT column_name, data_type, column_default, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'employee_employment'
  AND  column_name  = 'notice_period_days';

-- =============================================================================
-- END OF MIGRATION 483
-- =============================================================================
