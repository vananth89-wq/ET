-- =============================================================================
-- Migration 382 — VOID: date format standardisation (reversed)
--
-- Originally changed dates to dd/mm/yyyy. Reverted to mm/dd/yyyy per product
-- decision. This migration is a no-op placeholder to keep the migration
-- sequence intact.
-- =============================================================================

-- No-op: date format remains mm/dd/yyyy throughout the bulk system.
SELECT 'mig 382: no-op' AS status;
