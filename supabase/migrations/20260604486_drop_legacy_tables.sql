-- =============================================================================
-- Migration 486 — Drop legacy tables
--
-- These tables were renamed to *_legacy in mig 332 (set-snapshot rewrite,
-- 2026-05-29) and scheduled for DROP at "≥ 2026-06-14". Today is 2026-06-04.
-- No application code references them (confirmed by grep across src/).
-- Dropping now to reduce schema noise and prevent accidental writes.
--
-- Tables dropped:
--   employee_dependents_legacy
--   employee_bank_accounts_legacy
-- =============================================================================

DROP TABLE IF EXISTS employee_dependents_legacy CASCADE;
DROP TABLE IF EXISTS employee_bank_accounts_legacy CASCADE;

-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm tables no longer exist
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name IN ('employee_dependents_legacy', 'employee_bank_accounts_legacy');
-- Expected: 0 rows

-- =============================================================================
-- END OF MIGRATION 486
-- =============================================================================
