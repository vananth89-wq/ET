-- Migration : 20260806720_bulk_create_project_validity.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: bulk_create_timesheet_entries applies one entry to several dates, but never
--              checked that the chosen project was actually active on each of them. The day
--              panel filters its project dropdown by the selected date; the Create modal spans
--              many dates and could not, so an out-of-validity project could be written to
--              dates outside its start_date..end_date. Adds that check, returning the offending
--              dates so the UI can offer "Deselect these N dates" like the other scope errors.
--              Only this function changes — everything else in mig 719 is reproduced as-is.

CREATE OR REPLACE FUNCTION public.bulk_create_timesheet_entries(
  p_header_id uuid,
  p_dates     jsonb,
  p_entry     jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header    RECORD;
  v_dates     date[];
  v_d         date;
  v_clash     date[] := '{}';
  v_ahead     date[] := '{}';
  v_outside   date[] := '{}';
  v_inactive  date[] := '{}';
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_mins      integer;
  v_type      RECORD;
  v_proj      RECORD;
  v_proj_id   uuid;
  v_kind      text;
BEGIN
  SELECT id, employee_id, period, status INTO v_header
  FROM timesheet_headers WHERE id = p_header_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'HEADER_NOT_FOUND',
      'message', 'Timesheet not found.');
  END IF;

  IF NOT user_can('timesheet', 'edit', v_header.employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit this timesheet.');
  END IF;

  IF v_header.status <> 'to_be_submitted' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
      'message', 'This timesheet is no longer editable.');
  END IF;

  SELECT array_agg((value #>> '{}')::date ORDER BY (value #>> '{}')::date)
  INTO   v_dates
  FROM   jsonb_array_elements(p_dates);

  IF v_dates IS NULL OR array_length(v_dates, 1) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NO_DATES',
      'message', 'Select at least one date.');
  END IF;

  v_mins := COALESCE((p_entry->>'hours_minutes')::integer, 0);
  IF v_mins <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_DURATION',
      'message', 'Duration must be greater than 0.');
  END IF;

  SELECT id, category, requires_project INTO v_type
  FROM time_types WHERE id = (p_entry->>'time_type_id')::uuid AND is_active;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_TIME_TYPE',
      'message', 'Select a valid time type.');
  END IF;

  v_proj_id := NULLIF(p_entry->>'project_id','')::uuid;

  IF v_type.requires_project AND v_proj_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_REQUIRED',
      'message', 'This time type requires a project.');
  END IF;

  -- ── Project must exist, be active, and cover every selected date ──────────
  IF v_proj_id IS NOT NULL THEN
    SELECT id, name, active, start_date, end_date INTO v_proj
    FROM projects WHERE id = v_proj_id;

    IF NOT FOUND OR NOT v_proj.active THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_INACTIVE',
        'message', 'That project is no longer active.');
    END IF;

    FOREACH v_d IN ARRAY v_dates LOOP
      IF (v_proj.start_date IS NOT NULL AND v_d < v_proj.start_date)
      OR (v_proj.end_date   IS NOT NULL AND v_d > v_proj.end_date) THEN
        v_inactive := v_inactive || v_d;
      END IF;
    END LOOP;

    IF array_length(v_inactive, 1) > 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_NOT_ACTIVE_ON_DATE',
        'dates', to_jsonb(v_inactive),
        'message', format('%s is not active on all of the selected dates.', v_proj.name));
    END IF;
  END IF;

  v_kind := CASE WHEN v_type.category = 'absence' THEN 'leave' ELSE 'time_type' END;

  -- ── Remaining scope checks, all dates before any write ────────────────────
  FOREACH v_d IN ARRAY v_dates LOOP
    IF date_trunc('month', v_d)::date <> v_header.period THEN
      v_outside := v_outside || v_d;
    ELSIF v_d > CURRENT_DATE THEN
      v_ahead := v_ahead || v_d;
    ELSIF EXISTS (SELECT 1 FROM timesheet_entries e
                  WHERE e.header_id = p_header_id AND e.entry_date = v_d) THEN
      v_clash := v_clash || v_d;
    END IF;
  END LOOP;

  IF array_length(v_outside, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'OUTSIDE_PERIOD',
      'dates', to_jsonb(v_outside),
      'message', 'Attendance can only be created inside this timesheet month.');
  END IF;

  IF array_length(v_ahead, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'FUTURE_DATE',
      'dates', to_jsonb(v_ahead),
      'message', 'Attendance cannot be recorded in advance.');
  END IF;

  IF array_length(v_clash, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_EXISTS',
      'dates', to_jsonb(v_clash),
      'message', 'Attendance already exists for one or more of the selected dates.');
  END IF;

  -- ── Write. Any trigger rejection (mig 718 half-day rules) aborts the lot. ──
  FOREACH v_d IN ARRAY v_dates LOOP
    INSERT INTO timesheet_entries
      (header_id, entry_date, entry_kind, time_type_id, project_id,
       hours_minutes, notes, activities, created_by)
    VALUES
      (p_header_id, v_d, v_kind,
       (p_entry->>'time_type_id')::uuid,
       v_proj_id,
       v_mins,
       NULLIF(trim(COALESCE(p_entry->>'notes','')), ''),
       CASE WHEN jsonb_typeof(p_entry->'activities') = 'array'
                 AND jsonb_array_length(p_entry->'activities') > 0
            THEN ARRAY(SELECT jsonb_array_elements_text(p_entry->'activities'))
            ELSE NULL END,
       auth.uid())
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;

  PERFORM recalc_timesheet_recorded_minutes(p_header_id);

  RETURN jsonb_build_object(
    'ok', true,
    'created', array_length(v_ids, 1),
    'entry_ids', to_jsonb(v_ids),
    'dates', to_jsonb(v_dates)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) TO authenticated;
COMMENT ON FUNCTION public.bulk_create_timesheet_entries IS
  'Mig 720: as 719, plus the project must be active and cover every selected date. Returns PROJECT_NOT_ACTIVE_ON_DATE with the offending dates.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bulk_create_timesheet_entries') THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries missing.';
  END IF;
  RAISE NOTICE 'Migration 720 verified: bulk create now validates project validity per date.';
END $$;
