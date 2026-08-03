-- =============================================================================
-- Migration 709 — Standalone holidays + calendar assignment
--
-- Redesigns the holiday model so that:
--   1. time_holidays  = global pool of holiday definitions (no calendar FK)
--   2. time_calendar_holidays = junction: assign holidays to calendars
--
-- Breaking change from migration 698:
--   - Drops calendar_id column and its unique constraint from time_holidays
--   - Adds country_code + holiday_year to time_holidays for filtering
--   - Creates time_calendar_holidays junction table
--   - Replaces upsert_holiday and adds assign/unassign RPCs
-- =============================================================================

-- ── 1. Alter time_holidays — remove calendar coupling ─────────────────────────

-- Drop old unique constraint (calendar_id, holiday_date)
ALTER TABLE time_holidays
  DROP CONSTRAINT IF EXISTS time_holidays_unique_date;

-- Drop the calendar FK
ALTER TABLE time_holidays
  DROP CONSTRAINT IF EXISTS time_holidays_calendar_id_fkey;

-- Drop old index
DROP INDEX IF EXISTS idx_time_holidays_calendar_date;

-- Remove calendar_id column
ALTER TABLE time_holidays
  DROP COLUMN IF EXISTS calendar_id;

-- Add new columns
ALTER TABLE time_holidays
  ADD COLUMN IF NOT EXISTS country_code char(2),
  ADD COLUMN IF NOT EXISTS holiday_year integer GENERATED ALWAYS AS (EXTRACT(YEAR FROM holiday_date)::integer) STORED;

-- New unique constraint: one holiday per code (codes are globally unique identifiers)
ALTER TABLE time_holidays
  ADD CONSTRAINT time_holidays_code_key UNIQUE (holiday_code);

COMMENT ON TABLE  time_holidays IS 'Global pool of holiday definitions. Assign to calendars via time_calendar_holidays.';
COMMENT ON COLUMN time_holidays.country_code IS 'ISO 3166-1 alpha-2. Informational for filtering.';
COMMENT ON COLUMN time_holidays.holiday_year IS 'Computed from holiday_date for efficient year filtering.';

-- ── 2. Create junction table ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS time_calendar_holidays (
  calendar_id uuid NOT NULL REFERENCES time_holiday_calendars(id) ON DELETE CASCADE,
  holiday_id  uuid NOT NULL REFERENCES time_holidays(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES profiles(id),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (calendar_id, holiday_id)
);

COMMENT ON TABLE time_calendar_holidays IS 'Assigns holidays from the global pool to specific calendars.';

CREATE INDEX IF NOT EXISTS idx_cal_holidays_calendar
  ON time_calendar_holidays (calendar_id);
CREATE INDEX IF NOT EXISTS idx_cal_holidays_holiday
  ON time_calendar_holidays (holiday_id);

-- ── 3. RLS on junction table ──────────────────────────────────────────────────

ALTER TABLE time_calendar_holidays ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
CREATE POLICY "tch_select" ON time_calendar_holidays
  FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tch_insert" ON time_calendar_holidays
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_holiday_calendars', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
CREATE POLICY "tch_delete" ON time_calendar_holidays
  FOR DELETE TO authenticated
  USING (user_can('time_holiday_calendars', 'edit', NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 4. New/updated RPCs ───────────────────────────────────────────────────────

-- upsert_holiday: standalone (no calendar_id)
CREATE OR REPLACE FUNCTION upsert_holiday(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id     uuid;
  v_is_new boolean;
BEGIN
  v_id := (p_data->>'id')::uuid;
  IF v_id IS NOT NULL THEN
    IF NOT user_can('time_holidays', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit holidays.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_holidays', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to create holidays.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  IF (p_data->>'holiday_date') IS NULL OR (p_data->>'holiday_name') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'MISSING_FIELDS',
      'message', 'holiday_date and holiday_name are required.');
  END IF;

  INSERT INTO time_holidays (id, holiday_date, holiday_name, holiday_code, country_code, created_by)
  VALUES (
    v_id,
    (p_data->>'holiday_date')::date,
    trim(p_data->>'holiday_name'),
    upper(trim(p_data->>'holiday_code')),
    NULLIF(upper(trim(p_data->>'country_code')), ''),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    holiday_date = EXCLUDED.holiday_date,
    holiday_name = EXCLUDED.holiday_name,
    holiday_code = upper(trim(EXCLUDED.holiday_code)),
    country_code = EXCLUDED.country_code;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
    'message', 'A holiday with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_holiday(jsonb) TO authenticated;

-- assign_holiday_to_calendar
CREATE OR REPLACE FUNCTION assign_holiday_to_calendar(p_calendar_id uuid, p_holiday_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('time_holiday_calendars', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
  END IF;

  INSERT INTO time_calendar_holidays (calendar_id, holiday_id, assigned_by)
  VALUES (p_calendar_id, p_holiday_id, auth.uid())
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION assign_holiday_to_calendar(uuid, uuid) TO authenticated;

-- unassign_holiday_from_calendar
CREATE OR REPLACE FUNCTION unassign_holiday_from_calendar(p_calendar_id uuid, p_holiday_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('time_holiday_calendars', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Permission denied.');
  END IF;

  DELETE FROM time_calendar_holidays
  WHERE calendar_id = p_calendar_id AND holiday_id = p_holiday_id;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION unassign_holiday_from_calendar(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION upsert_holiday                    IS 'Mig 709: Create/update a standalone holiday definition.';
COMMENT ON FUNCTION assign_holiday_to_calendar        IS 'Mig 709: Assign a holiday to a calendar.';
COMMENT ON FUNCTION unassign_holiday_from_calendar    IS 'Mig 709: Remove a holiday from a calendar.';

-- ── 5. Verification ──────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'time_holidays' AND column_name = 'holiday_year') THEN
    RAISE EXCEPTION 'ABORT: time_holidays.holiday_year not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_calendar_holidays') THEN
    RAISE EXCEPTION 'ABORT: time_calendar_holidays not found.';
  END IF;
  RAISE NOTICE 'Migration 709 verified: holidays standalone + calendar assignment tables ready.';
END $$;
