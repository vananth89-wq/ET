-- =============================================================================
-- Migration 698 — Time Management: holiday calendar tables
--
-- Creates:
--   time_holiday_calendars   header (name, code, country_code)
--   time_holidays            individual holiday entries linked to a calendar + date
--
-- RLS: all authenticated users can read; write gated by
--   user_can('time_holiday_calendars', ...) and user_can('time_holidays', ...)
-- =============================================================================

-- ── 1. Calendar header ───────────────────────────────────────────────────────

CREATE TABLE time_holiday_calendars (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  code         text        NOT NULL,
  country_code char(2),
  is_active    boolean     NOT NULL DEFAULT true,
  created_by   uuid        REFERENCES profiles(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_holiday_calendars_code_key UNIQUE (code)
);

COMMENT ON TABLE  time_holiday_calendars IS 'Named holiday calendars, typically one per country.';
COMMENT ON COLUMN time_holiday_calendars.country_code IS 'ISO 3166-1 alpha-2. Informational — used for filtering in reports.';

-- ── 2. Individual holidays ───────────────────────────────────────────────────

CREATE TABLE time_holidays (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_id   uuid        NOT NULL REFERENCES time_holiday_calendars(id) ON DELETE CASCADE,
  holiday_date  date        NOT NULL,
  holiday_name  text        NOT NULL,
  holiday_code  text        NOT NULL,
  created_by    uuid        REFERENCES profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_holidays_unique_date UNIQUE (calendar_id, holiday_date)
);

COMMENT ON TABLE  time_holidays IS 'Individual holidays assigned to a calendar date. One per date per calendar.';
COMMENT ON COLUMN time_holidays.holiday_code IS 'Short code e.g. EID_FTR. Used in timesheet entry references.';

-- ── 3. Indexes ───────────────────────────────────────────────────────────────

CREATE INDEX idx_time_holidays_calendar_date
  ON time_holidays (calendar_id, holiday_date);

-- ── 4. RLS ───────────────────────────────────────────────────────────────────

ALTER TABLE time_holiday_calendars ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_holidays          ENABLE ROW LEVEL SECURITY;

-- Calendars
CREATE POLICY "thc_select" ON time_holiday_calendars
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "thc_insert" ON time_holiday_calendars
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_holiday_calendars', 'create', NULL));
CREATE POLICY "thc_update" ON time_holiday_calendars
  FOR UPDATE TO authenticated
  USING     (user_can('time_holiday_calendars', 'edit', NULL))
  WITH CHECK (user_can('time_holiday_calendars', 'edit', NULL));
CREATE POLICY "thc_delete" ON time_holiday_calendars
  FOR DELETE TO authenticated
  USING (user_can('time_holiday_calendars', 'delete', NULL));

-- Holidays
CREATE POLICY "th_select" ON time_holidays
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "th_insert" ON time_holidays
  FOR INSERT TO authenticated
  WITH CHECK (user_can('time_holidays', 'create', NULL));
CREATE POLICY "th_update" ON time_holidays
  FOR UPDATE TO authenticated
  USING     (user_can('time_holidays', 'edit', NULL))
  WITH CHECK (user_can('time_holidays', 'edit', NULL));
CREATE POLICY "th_delete" ON time_holidays
  FOR DELETE TO authenticated
  USING (user_can('time_holidays', 'delete', NULL));

-- ── 5. RPCs ──────────────────────────────────────────────────────────────────

-- upsert_holiday_calendar
CREATE OR REPLACE FUNCTION upsert_holiday_calendar(p_data jsonb)
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
    IF NOT user_can('time_holiday_calendars', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit holiday calendars.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_holiday_calendars', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to create holiday calendars.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  INSERT INTO time_holiday_calendars (id, name, code, country_code, is_active, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    upper(trim(p_data->>'country_code')),
    COALESCE((p_data->>'is_active')::boolean, true),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name         = trim(EXCLUDED.name),
    code         = upper(trim(EXCLUDED.code)),
    country_code = upper(trim(EXCLUDED.country_code)),
    is_active    = EXCLUDED.is_active,
    updated_at   = now();

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
    'message', 'A holiday calendar with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_holiday_calendar(jsonb) TO authenticated;

-- upsert_holiday
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

  IF (p_data->>'calendar_id') IS NULL OR (p_data->>'holiday_date') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'MISSING_FIELDS',
      'message', 'calendar_id and holiday_date are required.');
  END IF;

  INSERT INTO time_holidays (id, calendar_id, holiday_date, holiday_name, holiday_code, created_by)
  VALUES (
    v_id,
    (p_data->>'calendar_id')::uuid,
    (p_data->>'holiday_date')::date,
    trim(p_data->>'holiday_name'),
    upper(trim(p_data->>'holiday_code')),
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    holiday_date = EXCLUDED.holiday_date,
    holiday_name = EXCLUDED.holiday_name,
    holiday_code = EXCLUDED.holiday_code;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_DATE',
    'message', 'A holiday already exists on this date in this calendar.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_holiday(jsonb) TO authenticated;

COMMENT ON FUNCTION upsert_holiday_calendar IS 'Mig 698: Create/update a holiday calendar.';
COMMENT ON FUNCTION upsert_holiday          IS 'Mig 698: Create/update an individual holiday within a calendar.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_holiday_calendars') THEN
    RAISE EXCEPTION 'ABORT: time_holiday_calendars table not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'time_holidays') THEN
    RAISE EXCEPTION 'ABORT: time_holidays table not found.';
  END IF;
  RAISE NOTICE 'Migration 698 verified: time_holiday_calendars + time_holidays created.';
END $$;
