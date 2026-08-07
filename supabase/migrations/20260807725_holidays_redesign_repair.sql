-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 725: force the holiday redesign (migs 709 + 710) to actually land.
--
-- SYMPTOM
--   Admin → Time Management → Holidays → Add Holiday fails with
--   "calendar_id and holiday_date are required."
--
-- CAUSE
--   That message exists in exactly one place: the mig 698 version of
--   upsert_holiday(), from when time_holidays WAS the calendar×date table.
--   Migs 709 and 710 redesigned it — time_holidays became a pool of
--   code+name definitions, and dates moved to time_calendar_entries — and both
--   replaced upsert_holiday accordingly.
--
--   Dev is still running the 698 version. Combined with the earlier finding
--   that Dev's time_holidays still has the calendar_id column that 709 drops,
--   709/710 did not fully take effect there. time_calendar_entries DOES exist,
--   which points at 710 aborting partway: its table creation is near the top,
--   its function definitions are at the bottom.
--
-- WHAT THIS DOES
--   Re-applies the redesign's END STATE idempotently, so it does not matter how
--   far 709/710 got on any given environment. Every step is guarded, so this is
--   a no-op where the redesign already landed (a clean replay, for instance).
--
--   Data safety: any pool row still carrying a calendar_id + holiday_date is a
--   pre-redesign row. It is copied into time_calendar_entries BEFORE the columns
--   are dropped, so no holiday assignment is lost.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Report the starting state ───────────────────────────────────────────
DO $$
DECLARE v_cols text;
BEGIN
  SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'time_holidays';
  RAISE NOTICE 'Migration 725: time_holidays currently has: %', v_cols;
END $$;

-- ── 2. Rescue pre-redesign rows before dropping their columns ──────────────
DO $$
DECLARE v_moved integer := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='time_holidays'
                AND column_name='calendar_id')
     AND EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='time_holidays'
                AND column_name='holiday_date')
  THEN
    -- Dynamic SQL: these columns may not exist at parse time on a clean env.
    EXECUTE $q$
      INSERT INTO time_calendar_entries (calendar_id, entry_date, holiday_id, created_by)
      SELECT h.calendar_id, h.holiday_date, h.id, h.created_by
        FROM time_holidays h
       WHERE h.calendar_id IS NOT NULL
         AND h.holiday_date IS NOT NULL
         AND NOT EXISTS (
               SELECT 1 FROM time_calendar_entries ce
                WHERE ce.calendar_id = h.calendar_id
                  AND ce.entry_date  = h.holiday_date)
    $q$;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
  END IF;
  RAISE NOTICE 'Migration 725: rescued % pre-redesign holiday assignment(s) into time_calendar_entries.', v_moved;
END $$;

-- ── 3. Bring time_holidays to the pool shape (709 + 710 end state) ─────────
ALTER TABLE time_holidays DROP CONSTRAINT IF EXISTS time_holidays_unique_date;
ALTER TABLE time_holidays DROP CONSTRAINT IF EXISTS time_holidays_calendar_id_fkey;
DROP INDEX IF EXISTS idx_time_holidays_calendar_date;

ALTER TABLE time_holidays DROP COLUMN IF EXISTS calendar_id;    -- mig 709
ALTER TABLE time_holidays DROP COLUMN IF EXISTS holiday_year;   -- mig 710
ALTER TABLE time_holidays DROP COLUMN IF EXISTS holiday_date;   -- mig 710
ALTER TABLE time_holidays DROP COLUMN IF EXISTS country_code;   -- mig 710

ALTER TABLE time_holidays ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE time_holidays DROP CONSTRAINT IF EXISTS time_holidays_code_key;
ALTER TABLE time_holidays ADD  CONSTRAINT time_holidays_code_key UNIQUE (holiday_code);

COMMENT ON TABLE time_holidays IS
  'Global pool of holiday definitions (code + name). Dates are assigned per '
  'calendar in time_calendar_entries. Migs 709/710, repaired by 725.';

-- ── 4. The trigger 710 could not create (its helper was missing) ───────────
CREATE OR REPLACE FUNCTION public._set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_holidays_updated_at ON time_holidays;
CREATE TRIGGER trg_time_holidays_updated_at
  BEFORE UPDATE ON time_holidays
  FOR EACH ROW EXECUTE FUNCTION public._set_updated_at();

-- ── 5. The three RPCs the admin screens call ───────────────────────────────
CREATE OR REPLACE FUNCTION upsert_holiday(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id uuid; v_is_new boolean;
BEGIN
  v_id := (p_data->>'id')::uuid;
  IF v_id IS NOT NULL THEN
    IF NOT user_can('time_holidays', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'You do not have permission to edit holidays.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_holidays', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'You do not have permission to create holidays.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  -- A holiday DEFINITION is code + name. Dates belong to time_calendar_entries.
  IF NULLIF(trim(p_data->>'holiday_code'), '') IS NULL
     OR NULLIF(trim(p_data->>'holiday_name'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'MISSING_FIELDS',
      'message', 'Code and name are required.');
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

REVOKE ALL ON FUNCTION upsert_holiday(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_holiday(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION upsert_calendar_entry(
  p_calendar_id uuid, p_entry_date date, p_holiday_id uuid, p_entry_id uuid DEFAULT NULL)
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

REVOKE ALL ON FUNCTION upsert_calendar_entry(uuid, date, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_calendar_entry(uuid, date, uuid, uuid) TO authenticated;

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

REVOKE ALL ON FUNCTION delete_calendar_entry(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_calendar_entry(uuid) TO authenticated;

COMMENT ON FUNCTION upsert_holiday        IS 'Mig 725: create/update a holiday DEFINITION (code + name only).';
COMMENT ON FUNCTION upsert_calendar_entry IS 'Mig 725: add/update a date→holiday entry within a calendar.';
COMMENT ON FUNCTION delete_calendar_entry IS 'Mig 725: remove a calendar entry row.';

-- ── 6. planned_minutes may have moved; resync the open window ──────────────
DO $$
DECLARE r record; v_after integer; v_fixed integer := 0;
        v_floor date := (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months')::date;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'time_recalc_planned_minutes') THEN
    FOR r IN SELECT id, planned_minutes FROM timesheet_headers WHERE period >= v_floor LOOP
      v_after := time_recalc_planned_minutes(r.id);
      IF v_after IS DISTINCT FROM r.planned_minutes THEN v_fixed := v_fixed + 1; END IF;
    END LOOP;
  END IF;
  RAISE NOTICE 'Migration 725: corrected planned_minutes on % header(s).', v_fixed;
END $$;

-- ── 7. Verify ──────────────────────────────────────────────────────────────
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['calendar_id','holiday_date','holiday_year','country_code'] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='time_holidays' AND column_name=c) THEN
      RAISE EXCEPTION 'ABORT: time_holidays.% still exists — the pool shape was not reached.', c;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE proname = 'upsert_holiday'
                AND prosrc LIKE '%calendar_id and holiday_date are required%') THEN
    RAISE EXCEPTION 'ABORT: the mig 698 version of upsert_holiday is still installed.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'upsert_calendar_entry')
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_calendar_entry') THEN
    RAISE EXCEPTION 'ABORT: the calendar-entry RPCs are missing.';
  END IF;

  RAISE NOTICE 'Migration 725 verified: time_holidays is a pool, dates live in time_calendar_entries.';
END $$;
