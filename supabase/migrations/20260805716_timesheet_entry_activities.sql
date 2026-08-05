-- =============================================================================
-- Migration 716 — Add activities array to timesheet_entries
--
-- When an attendance time type has requires_project=true, employees log
-- one or more activities against the project. Stored as text[] for
-- simplicity; each element is a free-text activity description.
-- NULL for non-project entries.
-- =============================================================================

ALTER TABLE timesheet_entries
  ADD COLUMN IF NOT EXISTS activities text[] DEFAULT NULL;

COMMENT ON COLUMN timesheet_entries.activities IS
  'Activity descriptions for project-linked time entries (requires_project time types). NULL for all other entry kinds.';

-- Verification
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'timesheet_entries' AND column_name = 'activities'
  ) THEN
    RAISE EXCEPTION 'ABORT: activities column not found on timesheet_entries.';
  END IF;
  RAISE NOTICE 'Migration 716 verified: activities column added to timesheet_entries.';
END $$;
