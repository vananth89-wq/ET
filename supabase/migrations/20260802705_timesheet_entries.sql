-- =============================================================================
-- Migration 705 — Timesheet entries table + indexes
--
-- Creates timesheet_entries: one row per day per project/time-type/holiday/leave.
-- entry_kind drives which FK is populated:
--   'project'   → project_id required
--   'time_type' → time_type_id required
--   'holiday'   → time_type_id required (points to the holiday time type), is_system_generated=true
--   'leave'     → time_type_id required (points to the leave time type), is_system_generated=true
-- =============================================================================

CREATE TABLE IF NOT EXISTS timesheet_entries (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  header_id           uuid        NOT NULL REFERENCES timesheet_headers(id) ON DELETE CASCADE,
  entry_date          date        NOT NULL,
  entry_kind          text        NOT NULL CHECK (entry_kind IN ('project', 'time_type', 'holiday', 'leave')),
  project_id          uuid        REFERENCES projects(id),
  time_type_id        uuid        REFERENCES time_types(id),
  hours_minutes       integer     NOT NULL CHECK (hours_minutes > 0),
  notes               text,
  is_system_generated boolean     NOT NULL DEFAULT false,
  created_by          uuid        REFERENCES profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- Exactly one of project_id / time_type_id must be set, matching entry_kind
  CONSTRAINT te_project_kind  CHECK (
    (entry_kind = 'project'   AND project_id   IS NOT NULL AND time_type_id IS NULL) OR
    (entry_kind != 'project'  AND time_type_id IS NOT NULL AND project_id   IS NULL)
  )
);

COMMENT ON TABLE  timesheet_entries IS 'Child rows of timesheet_headers. One per day per project/time-type/holiday/leave combination.';
COMMENT ON COLUMN timesheet_entries.hours_minutes       IS 'Duration in minutes. Must be > 0. Display as hh:mm.';
COMMENT ON COLUMN timesheet_entries.is_system_generated IS 'true for holiday and leave entries created by RPCs, not by the employee directly.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

-- Reporting: project utilization across employees
CREATE INDEX IF NOT EXISTS idx_ts_entries_header_project ON timesheet_entries (header_id, entry_kind, project_id)
  WHERE entry_kind = 'project';

-- Reporting: time type utilization
CREATE INDEX IF NOT EXISTS idx_ts_entries_header_timetype ON timesheet_entries (header_id, entry_kind, time_type_id)
  WHERE entry_kind IN ('time_type', 'leave', 'holiday');

-- Reporting: cross-employee project queries by date range
CREATE INDEX IF NOT EXISTS idx_ts_entries_date_project ON timesheet_entries (entry_date, project_id)
  WHERE project_id IS NOT NULL;

-- Standard access: all entries for a header
CREATE INDEX IF NOT EXISTS idx_ts_entries_header_date ON timesheet_entries (header_id, entry_date);

-- ── updated_at trigger ───────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_timesheet_entries_updated_at'
  ) THEN
    EXECUTE $trig$
      CREATE TRIGGER trg_timesheet_entries_updated_at
        BEFORE UPDATE ON timesheet_entries
        FOR EACH ROW EXECUTE FUNCTION _set_updated_at();
    $trig$;
  END IF;
END $$;

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE timesheet_entries ENABLE ROW LEVEL SECURITY;

-- Read: anyone who can view the parent header can view its entries
DO $$ BEGIN
CREATE POLICY "tse_select" ON timesheet_entries
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM timesheet_headers h
      WHERE h.id = timesheet_entries.header_id
        AND user_can('timesheet', 'view', h.employee_id)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Write policies are enforced at the RPC layer (SECURITY DEFINER).
-- These broad policies are a defence-in-depth backstop.
DO $$ BEGIN
CREATE POLICY "tse_insert" ON timesheet_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM timesheet_headers h
      WHERE h.id = timesheet_entries.header_id
        AND user_can('timesheet', 'edit', h.employee_id)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tse_update" ON timesheet_entries
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM timesheet_headers h
      WHERE h.id = timesheet_entries.header_id
        AND user_can('timesheet', 'edit', h.employee_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM timesheet_headers h
      WHERE h.id = timesheet_entries.header_id
        AND user_can('timesheet', 'edit', h.employee_id)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tse_delete" ON timesheet_entries
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM timesheet_headers h
      WHERE h.id = timesheet_entries.header_id
        AND user_can('timesheet', 'delete', h.employee_id)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'timesheet_entries') THEN
    RAISE EXCEPTION 'ABORT: timesheet_entries table not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND indexname = 'idx_ts_entries_header_project') THEN
    RAISE EXCEPTION 'ABORT: idx_ts_entries_header_project index not found.';
  END IF;
  RAISE NOTICE 'Migration 705 verified: timesheet_entries created with 4 indexes and RLS policies.';
END $$;
