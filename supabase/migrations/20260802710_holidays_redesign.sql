-- =============================================================================
-- Migration 710 — Holiday model final redesign
--
-- time_holidays        = date-less definitions: code + name + audit
-- time_holiday_calendars = header: code + name + country + is_active
-- time_calendar_entries  = child rows: calendar_id + entry_date + holiday_id
--
-- Replaces migration 709's junction table with proper child-row model.
-- =============================================================================

-- ── 1. Clean up prior schema (from migrations 698 + 709) ─────────────────────

DROP TABLE IF EXISTS time_calendar_holidays CASCADE;

-- Remove date-related columns added in 709 (holiday_year is generated, drop first)
ALTER TABLE time_holidays DROP COLUMN IF EXISTS holiday_year;
ALTER TABLE time_holidays DROP COLUMN IF EXISTS holiday_date;
ALTER TABLE time_holidays DROP COLUMN IF EXISTS country_code;

-- Drop old unique constraint on code if not present, add if missing
ALTER TABLE time_holidays DROP CONSTRAINT IF EXISTS time_holidays_code_key;
ALTER TABLE time_holidays ADD CONSTRAINT time_holidays_code_key UNIQUE (holiday_code);

-- Add updated_at if not present
ALTER TABLE time_holidays ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- ── 2. Create time_calendar_entries ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS time_calendar_entries (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_id uuid        NOT NULL REFERENCES time_holiday_calendars(id) ON DELETE CASCADE,
  entry_date  date        NOT NULL,
  holiday_id  uuid        NOT NULL REFERENCES time_holidays(id),
  created_by  uuid        REFERENCES profiles(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_calendar_entries_unique_date UNIQUE (calendar_id, entry_date)
);

COMMENT ON TABLE  time_calendar_entries IS 'Child rows of holiday calendars. One holiday per date per calendar.';
COMMENT ON COLUMN time_calendar_entries.entry_date  IS 'The date this holiday falls on in this calendar year.';
COMMENT ON COLUMN time_calendar_entries.holiday_id  IS 'Points to the holiday definition in time_holidays.';

CREATE INDEX IF NOT EXISTS idx_cal_entries_calendar_date
  ON time_calendar_entries (calendar_id, entry_date);

-- ── 3. RLS on time_calendar_entries ──────────────────────────────────────────

ALTER TABLE time_calendar_entries ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
CREATE POLICY "tce_select" ON time_calendar_entries
  FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tce_insert" ON time_calendar_entries
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_holiday_calendars', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tce_delete" ON time_calendar_entries
  FOR DELETE TO authenticated
  USING (user_can('time_holiday_calendars', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 4. updated_at trigger on time_holidays ────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_time_holidays_updated_at'
  ) THEN
    EXECUTE $trig$
      CREATE TRIGGER trg_time_holidays_updated_at
        BEFORE UPDATE ON time_holidays
        FOR EACH ROW EXECUTE FUNCTION _set_updated_at();
    $trig$;
  END IF;
END $$;

-- ── 5. RPCs ───────────────────────────────────────────────────────────────────

-- upsert_holiday: code + name only (no date)
CREATE OR REPLACE FUNCTION upsert_holiday(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id     uuid;
  v_is_new boolean;
BEGIN
  v_id := (p_data->>'id')::uuid;
  IF v_id IS NOT NULL THEN
    IF NOT user_can('time_holidays', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_holidays', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  IF trim(p_data->>'holiday_name') = '' OR trim(p_data->>'holiday_code') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'holiday_name and holiday_code are required.');
  END IF;

  INSERT INTO time_holidays (id, holiday_code, holiday_name, created_by)
  VALUES (v_id, upper(trim(p_data->>'holiday_code')), trim(p_data->>'holiday_name'), auth.uid())
  ON CONFLICT (id) DO UPDATE SET
    holiday_code = upper(trim(EXCLUDED.holiday_code)),
    holiday_name = trim(EXCLUDED.holiday_name),
    updated_at   = now();

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'message', 'A holiday with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION upsert_holiday(jsonb) TO authenticated;

-- upsert_calendar_entry: add/update a date→holiday entry in a calendar
CREATE OR REPLACE FUNCTION upsert_calendar_entry(
  p_calendar_id uuid,
  p_entry_date  date,
  p_holiday_id  uuid,
  p_entry_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT user_can('time_holiday_calendars', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
  END IF;

  v_id := COALESCE(p_entry_id, gen_random_uuid());

  INSERT INTO time_calendar_entries (id, calendar_id, entry_date, holiday_id, created_by)
  VALUES (v_id, p_calendar_id, p_entry_date, p_holiday_id, auth.uid())
  ON CONFLICT (id) DO UPDATE SET
    entry_date = EXCLUDED.entry_date,
    holiday_id = EXCLUDED.holiday_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'message', 'A holiday entry already exists for this date in this calendar.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION upsert_calendar_entry(uuid, date, uuid, uuid) TO authenticated;

-- delete_calendar_entry
CREATE OR REPLACE FUNCTION delete_calendar_entry(p_entry_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT user_can('time_holiday_calendars', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
  END IF;
  DELETE FROM time_calendar_entries WHERE id = p_entry_id;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION delete_calendar_entry(uuid) TO authenticated;

COMMENT ON FUNCTION upsert_holiday            IS 'Mig 710: Create/update a holiday definition (code+name only).';
COMMENT ON FUNCTION upsert_calendar_entry     IS 'Mig 710: Add/update a date→holiday entry within a calendar.';
COMMENT ON FUNCTION delete_calendar_entry     IS 'Mig 710: Remove a calendar entry row.';

-- ── 6. Verification ──────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_calendar_entries') THEN
    RAISE EXCEPTION 'ABORT: time_calendar_entries not found.';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'time_holidays' AND column_name = 'holiday_date') THEN
    RAISE EXCEPTION 'ABORT: holiday_date column still present on time_holidays.';
  END IF;
  RAISE NOTICE 'Migration 710 verified: holidays redesigned, time_calendar_entries created.';
END $$;
