-- Migration : 20260806718_time_types_allows_half_day.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: Renames time_types.allows_partial_overlap -> allows_half_day and makes it
--              mean what it says: "this absence may be taken as a partial day". The old
--              flag was written by the admin screen and read by nothing — the documented
--              behaviour ("absence blocks the day unless the flag is set") was never
--              implemented. Adds real enforcement via a trigger on timesheet_entries,
--              gates the flag to absence types (mirroring requires_project on attendance),
--              and marks system-managed types so Public Holiday stops being employee-selectable.

-- ── 1. Rename the flag ───────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='time_types'
               AND column_name='allows_partial_overlap')
     AND NOT EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='time_types'
               AND column_name='allows_half_day') THEN
    ALTER TABLE public.time_types RENAME COLUMN allows_partial_overlap TO allows_half_day;
    RAISE NOTICE 'Migration 718: renamed allows_partial_overlap -> allows_half_day';
  END IF;
END $$;

ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS allows_half_day boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.time_types.allows_half_day IS
  'Absence types only. true = this leave may be taken for less than the planned day, and attendance may be logged alongside it. false = the entry is locked to the full planned day and blocks all other entries.';

-- Half day is meaningless on an attendance type — mirror of requires_project.
UPDATE public.time_types SET allows_half_day = false WHERE category <> 'absence' AND allows_half_day;

-- ── 2. System-managed types are not employee-selectable ──────────────────────
ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS is_system_managed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.time_types.is_system_managed IS
  'true = rows of this type are created by the system (holiday sync, leave module), never chosen by an employee. Hidden from the ESS time-type picker.';

UPDATE public.time_types SET is_system_managed = true WHERE code = 'HOL';

-- ── 3. upsert_time_type: gate each flag to its own category ──────────────────
CREATE OR REPLACE FUNCTION public.upsert_time_type(p_data jsonb)
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
    IF NOT user_can('time_types', 'edit', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to edit time types.');
    END IF;
    v_is_new := false;
  ELSE
    IF NOT user_can('time_types', 'create', NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
        'message', 'You do not have permission to create time types.');
    END IF;
    v_id := gen_random_uuid();
    v_is_new := true;
  END IF;

  IF (p_data->>'category') NOT IN ('attendance', 'absence') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CATEGORY',
      'message', 'category must be attendance or absence.');
  END IF;

  INSERT INTO time_types (id, name, code, category, allows_half_day, is_active, requires_project, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    p_data->>'category',
    -- allows_half_day  → absence only
    CASE WHEN p_data->>'category' = 'absence'
         THEN COALESCE((p_data->>'allows_half_day')::boolean, false)
         ELSE false END,
    COALESCE((p_data->>'is_active')::boolean, true),
    -- requires_project → attendance only
    CASE WHEN p_data->>'category' = 'attendance'
         THEN COALESCE((p_data->>'requires_project')::boolean, false)
         ELSE false END,
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE SET
    name             = trim(EXCLUDED.name),
    code             = upper(trim(EXCLUDED.code)),
    category         = EXCLUDED.category,
    allows_half_day  = CASE WHEN EXCLUDED.category = 'absence'   THEN EXCLUDED.allows_half_day  ELSE false END,
    requires_project = CASE WHEN EXCLUDED.category = 'attendance' THEN EXCLUDED.requires_project ELSE false END,
    is_active        = EXCLUDED.is_active,
    updated_at       = now();

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', v_is_new);

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
    'message', 'A time type with this code already exists.');
WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_time_type(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_time_type(jsonb) TO authenticated;
COMMENT ON FUNCTION public.upsert_time_type IS
  'Mig 718: create/update a time type. allows_half_day is forced false for attendance; requires_project is forced false for absence.';

-- ── 4. Planned minutes for one date, from the header snapshot ────────────────
-- Uses the header's snapshotted schedule + calendar, not the employee's current
-- employment, so historical months stay correct. A holiday counts as 0 planned,
-- matching how timesheet_headers.planned_minutes is summed (mig 701).
CREATE OR REPLACE FUNCTION public.time_planned_minutes_for_date(p_header_id uuid, p_date date)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN EXISTS (
      -- CORRECTED 2026-08-07: holidays live in time_calendar_entries (mig 710).
      -- time_holidays is the global POOL and mig 709 dropped its calendar_id, so
      -- the original form here aborted on any environment where 709 applied.
      SELECT 1 FROM time_calendar_entries ce
      JOIN timesheet_headers h2 ON h2.id = p_header_id
      WHERE ce.calendar_id = h2.holiday_calendar_id AND ce.entry_date = p_date
    ) THEN 0
    ELSE COALESCE((
      SELECT l.planned_minutes
      FROM   timesheet_headers h
      JOIN   time_work_schedules      ws ON ws.id = h.work_schedule_id
      JOIN   time_work_schedule_lines l  ON l.work_schedule_id = ws.id
                 AND l.day_number = ((EXTRACT(DOW FROM p_date)::int - ws.start_day_of_week + 7) % 7) + 1
      WHERE  h.id = p_header_id
    ), 0)
  END;
$$;

REVOKE ALL ON FUNCTION public.time_planned_minutes_for_date(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_planned_minutes_for_date(uuid, date) TO authenticated;
COMMENT ON FUNCTION public.time_planned_minutes_for_date IS
  'Mig 718: planned minutes for a single date on a timesheet header. Holidays return 0. Respects the schedule start_day_of_week.';

-- ── 5. Enforce the half-day rules ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_timesheet_entry_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_planned   integer;
  v_half      boolean;
  v_other_abs integer;
  v_other_att integer;
  v_blocking  integer;
BEGIN
  -- System-generated rows (holiday sync, leave module) bypass these rules.
  IF NEW.is_system_generated THEN RETURN NEW; END IF;

  v_planned := time_planned_minutes_for_date(NEW.header_id, NEW.entry_date);

  IF NEW.entry_kind = 'leave' THEN
    -- (a) no leave on a day that was never scheduled
    IF v_planned = 0 THEN
      RAISE EXCEPTION 'Leave cannot be recorded on a non-working day or public holiday.'
        USING ERRCODE = 'check_violation';
    END IF;

    -- (b) at most one absence per day
    SELECT count(*) INTO v_other_abs
    FROM   timesheet_entries e
    WHERE  e.header_id  = NEW.header_id
      AND  e.entry_date = NEW.entry_date
      AND  e.entry_kind = 'leave'
      AND  e.id IS DISTINCT FROM NEW.id;
    IF v_other_abs > 0 THEN
      RAISE EXCEPTION 'Only one leave entry is allowed per day.'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(tt.allows_half_day, false) INTO v_half
    FROM time_types tt WHERE tt.id = NEW.time_type_id;

    IF NOT COALESCE(v_half, false) THEN
      -- (c) a full-day-only leave must cover exactly the planned day
      IF NEW.hours_minutes <> v_planned THEN
        RAISE EXCEPTION 'This leave type must be recorded as a full day (% minutes).', v_planned
          USING ERRCODE = 'check_violation';
      END IF;
      -- (d) and nothing else may share the day
      SELECT count(*) INTO v_other_att
      FROM   timesheet_entries e
      WHERE  e.header_id  = NEW.header_id
        AND  e.entry_date = NEW.entry_date
        AND  e.entry_kind <> 'leave'
        AND  e.id IS DISTINCT FROM NEW.id;
      IF v_other_att > 0 THEN
        RAISE EXCEPTION 'A full-day leave cannot be recorded on a day that already has attendance.'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

  ELSE
    -- attendance: blocked only by a full-day-only leave already on the day
    SELECT count(*) INTO v_blocking
    FROM   timesheet_entries e
    JOIN   time_types tt ON tt.id = e.time_type_id
    WHERE  e.header_id  = NEW.header_id
      AND  e.entry_date = NEW.entry_date
      AND  e.entry_kind = 'leave'
      AND  COALESCE(tt.allows_half_day, false) = false
      AND  e.id IS DISTINCT FROM NEW.id;
    IF v_blocking > 0 THEN
      RAISE EXCEPTION 'A full-day leave is already recorded for this day.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_timesheet_entry_rules() FROM PUBLIC;
COMMENT ON FUNCTION public.enforce_timesheet_entry_rules IS
  'Mig 718: enforces the half-day leave rules on timesheet_entries. Lives in the DB because the day panel, the Create modal and bulk paste all write entries.';

DROP TRIGGER IF EXISTS trg_timesheet_entry_rules ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_rules
  BEFORE INSERT OR UPDATE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_timesheet_entry_rules();

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='time_types' AND column_name='allows_half_day') THEN
    RAISE EXCEPTION 'ABORT: time_types.allows_half_day not found.';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='time_types' AND column_name='allows_partial_overlap') THEN
    RAISE EXCEPTION 'ABORT: allows_partial_overlap still present — rename did not apply.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_timesheet_entry_rules') THEN
    RAISE EXCEPTION 'ABORT: trg_timesheet_entry_rules not created.';
  END IF;
  IF EXISTS (SELECT 1 FROM time_types WHERE category <> 'absence' AND allows_half_day) THEN
    RAISE EXCEPTION 'ABORT: allows_half_day set on a non-absence type.';
  END IF;
  RAISE NOTICE 'Migration 718 verified: allows_half_day renamed + gated, is_system_managed added, entry rules trigger active.';
END $$;
