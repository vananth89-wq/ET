-- =============================================================================
-- Migration : 20260420005_picklist_values_meta.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Adds a meta JSONB column to picklist_values so that picklist
--              entries can carry arbitrary key/value pairs (e.g. ISO code,
--              symbol, currencyId) without requiring dedicated columns.
-- =============================================================================

ALTER TABLE picklist_values
  ADD COLUMN IF NOT EXISTS meta JSONB DEFAULT NULL;

-- =============================================================================
-- END OF MIGRATION 20260420005_picklist_values_meta.sql
-- =============================================================================
