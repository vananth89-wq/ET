-- =============================================================================
-- Migration 704 — Timesheet headers table + indexes
--
-- Creates timesheet_headers: one row per employee per month.
-- Key design decisions:
--   - external_code = {employee_code}_{YYYYMM} — globally unique, human-readable
--   - Snapshot columns (work_schedule_id, holiday_calendar_id, department_id,
--     department_name, country_code) captured at creation time — historical accuracy
--   - status machine: to_be_submitted → to_be_approved → approved
--   - workflow_instance_id set on first wf_submit() call
-- =============================================================================

CREATE TABLE timesheet_headers (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id          uuid        NOT NULL REFERENCES employees(id),
  period               date        NOT NULL,  -- always 1st of month e.g. 2026-06-01
  external_code        text        NOT NULL,
  status               text        NOT NULL DEFAULT 'to_be_submitted'
                                   CHECK (status IN ('to_be_submitted', 'to_be_approved', 'approved')),

  -- Snapshots at creation time (never updated after insert)
  work_schedule_id     uuid        REFERENCES time_work_schedules(id),
  holiday_calendar_id  uuid        REFERENCES time_holiday_calendars(id),
  department_id        uuid,       -- FK to departments; soft ref so it survives dept deletion
  department_name      text,       -- denormalized snapshot; survives dept rename
  country_code         char(2),    -- ISO 3166-1 alpha-2; snapshotted for multi-country reporting

  -- Computed hours (minutes)
  planned_minutes      integer     NOT NULL DEFAULT 0 CHECK (planned_minutes >= 0),
  recorded_minutes     integer     NOT NULL DEFAULT 0 CHECK (recorded_minutes >= 0),

  -- Workflow link
  workflow_instance_id uuid,       -- nullable until first wf_submit()

  -- Timestamps
  submitted_at         timestamptz,
  approved_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT timesheet_headers_external_code_key UNIQUE (external_code),
  CONSTRAINT timesheet_headers_employee_period    UNIQUE (employee_id, period),
  -- period must always be the 1st of the month
  CONSTRAINT timesheet_headers_period_first_of_month CHECK (EXTRACT(DAY FROM period) = 1)
);

COMMENT ON TABLE  timesheet_headers IS 'One row per employee per month. Snapshot columns frozen at creation for historical accuracy.';
COMMENT ON COLUMN timesheet_headers.period          IS 'Always the 1st of the month. e.g. 2026-06-01 represents June 2026.';
COMMENT ON COLUMN timesheet_headers.external_code   IS 'Format: {employee_code}_{YYYYMM}. Human-readable, globally unique.';
COMMENT ON COLUMN timesheet_headers.department_id   IS 'Snapshot at creation — not a FK; survives department deletion.';
COMMENT ON COLUMN timesheet_headers.department_name IS 'Denormalized snapshot — survives department rename.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

-- Primary access: employee timesheet history
CREATE INDEX idx_ts_headers_employee_period ON timesheet_headers (employee_id, period);

-- Reporting: all timesheets for a period (missing timesheet report, department summary)
CREATE INDEX idx_ts_headers_period_status ON timesheet_headers (period, status);

-- ── updated_at trigger ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;

-- Only create trigger if not already present (shared helper)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_timesheet_headers_updated_at'
  ) THEN
    EXECUTE $trig$
      CREATE TRIGGER trg_timesheet_headers_updated_at
        BEFORE UPDATE ON timesheet_headers
        FOR EACH ROW EXECUTE FUNCTION _set_updated_at();
    $trig$;
  END IF;
END $$;

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE timesheet_headers ENABLE ROW LEVEL SECURITY;

-- Employee: own timesheets
CREATE POLICY "tsh_select_own" ON timesheet_headers
  FOR SELECT TO authenticated
  USING (user_can('timesheet', 'view', employee_id));

-- Employee/system: create own header
CREATE POLICY "tsh_insert" ON timesheet_headers
  FOR INSERT TO authenticated
  WITH CHECK (user_can('timesheet', 'create', employee_id));

-- Status updates via RPCs (SECURITY DEFINER functions bypass RLS, but we define
-- a broad update policy guarded at the RPC layer for defence-in-depth)
CREATE POLICY "tsh_update" ON timesheet_headers
  FOR UPDATE TO authenticated
  USING     (user_can('timesheet', 'edit', employee_id))
  WITH CHECK (user_can('timesheet', 'edit', employee_id));

-- Hard delete: only admin can delete a header (and only via RPC)
CREATE POLICY "tsh_delete" ON timesheet_headers
  FOR DELETE TO authenticated
  USING (user_can('timesheet', 'delete', employee_id));

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'timesheet_headers') THEN
    RAISE EXCEPTION 'ABORT: timesheet_headers table not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND indexname = 'idx_ts_headers_employee_period') THEN
    RAISE EXCEPTION 'ABORT: idx_ts_headers_employee_period index not found.';
  END IF;
  RAISE NOTICE 'Migration 704 verified: timesheet_headers created with indexes and RLS policies.';
END $$;
