-- Migration : 20260806719_timesheet_bulk_create.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: Backs the timesheet "Create" toolbar action, which applies one attendance
--              entry to several dates at once. Doing this as N client-side inserts leaves
--              the user unable to tell what landed if one fails halfway, and makes the
--              duplicate check racy. bulk_create_timesheet_entries does the scope checks
--              and the writes in a single transaction and returns the new ids so the
--              success toast can offer Undo. delete_timesheet_entries is that Undo.

-- ── 1. Shared recalc — defined first, both RPCs below call it ───────────────
CREATE OR REPLACE FUNCTION public.recalc_timesheet_recorded_minutes(p_header_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE timesheet_headers h
  SET    recorded_minutes = COALESCE(
           (SELECT SUM(e.hours_minutes) FROM timesheet_entries e WHERE e.header_id = h.id), 0),
         updated_at = now()
  WHERE  h.id = p_header_id;
$$;

REVOKE ALL ON FUNCTION public.recalc_timesheet_recorded_minutes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalc_timesheet_recorded_minutes(uuid) TO authenticated;
COMMENT ON FUNCTION public.recalc_timesheet_recorded_minutes IS
  'Mig 719: recomputes timesheet_headers.recorded_minutes from its entries. Authoritative — the client no longer has to sum and write it back.';

-- ── 2. Bulk create ───────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.bulk_create_timesheet_entries(uuid, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.bulk_create_timesheet_entries(
  p_header_id uuid,
  p_dates     jsonb,      -- ["2026-08-04","2026-08-05"]
  p_entry     jsonb       -- { time_type_id, project_id, hours_minutes, notes, activities }
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
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_mins      integer;
  v_type      RECORD;
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

  IF v_type.requires_project AND (p_entry->>'project_id') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_REQUIRED',
      'message', 'This time type requires a project.');
  END IF;

  -- Mirrors MyTimesheet: an absence is 'leave', everything else is 'time_type'
  -- (a project entry is 'time_type' with BOTH ids set — see constraint te_project_kind).
  v_kind := CASE WHEN v_type.category = 'absence' THEN 'leave' ELSE 'time_type' END;

  -- ── Scope checks, all dates before any write ──────────────────────────────
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
       NULLIF(p_entry->>'project_id','')::uuid,
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
  'Mig 719: applies one attendance entry to many dates in a single transaction. Returns entry_ids so the UI can offer Undo. All scope checks run before any write.';

-- ── 3. Undo — delete a set of entries the caller just created ────────────────
DROP FUNCTION IF EXISTS public.delete_timesheet_entries(uuid[]);

CREATE OR REPLACE FUNCTION public.delete_timesheet_entries(p_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header_id uuid;
  v_emp       uuid;
  v_deleted   integer;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'deleted', 0);
  END IF;

  -- Every id must belong to one header, and the caller must own that header.
  SELECT DISTINCT e.header_id INTO v_header_id
  FROM timesheet_entries e WHERE e.id = ANY(p_ids);

  IF v_header_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'deleted', 0);   -- already gone
  END IF;

  IF (SELECT count(DISTINCT header_id) FROM timesheet_entries WHERE id = ANY(p_ids)) > 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'MIXED_HEADERS',
      'message', 'Entries span more than one timesheet.');
  END IF;

  SELECT employee_id INTO v_emp FROM timesheet_headers WHERE id = v_header_id;

  IF NOT user_can('timesheet', 'edit', v_emp) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit this timesheet.');
  END IF;

  DELETE FROM timesheet_entries WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  PERFORM recalc_timesheet_recorded_minutes(v_header_id);

  RETURN jsonb_build_object('ok', true, 'deleted', v_deleted);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_timesheet_entries(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_timesheet_entries(uuid[]) TO authenticated;
COMMENT ON FUNCTION public.delete_timesheet_entries IS
  'Mig 719: deletes a set of entries by id. Backs Undo on bulk create and on paste.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bulk_create_timesheet_entries') THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries missing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'delete_timesheet_entries') THEN
    RAISE EXCEPTION 'ABORT: delete_timesheet_entries missing.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'recalc_timesheet_recorded_minutes') THEN
    RAISE EXCEPTION 'ABORT: recalc_timesheet_recorded_minutes missing.';
  END IF;
  RAISE NOTICE 'Migration 719 verified: bulk create + undo + recalc in place.';
END $$;
