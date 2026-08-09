-- Migration : 20260807728_activity_rpcs_safeupdate_fix.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: HOTFIX for mig 727. Saving an itemised entry failed on Dev with
--
--                  DELETE requires a WHERE clause
--
--              Supabase loads pg_safeupdate, which rejects any UPDATE or DELETE
--              that has no WHERE clause. Both RPCs added by 727 clear a scratch
--              TEMP table with a bare `DELETE FROM _tea_in;` / `DELETE FROM
--              _bulk_acts;` before refilling it, and pg_safeupdate does not care
--              that the target is a temp table the same transaction just made.
--
--              Every DELETE that touches real data was already qualified
--              (`WHERE entry_id = v_id`), so no row was ever at risk -- the
--              function simply could not complete. Symptom: "DELETE requires a
--              WHERE clause" shown in the entry form on Save.
--
--              Fix: TRUNCATE instead. It is not covered by the guard, and it
--              states the intent better than deleting every row one predicate
--              short of a mistake.
--
-- WHY THE TESTS MISSED IT
--   727 was exercised against a stand-in PostgreSQL 16 with 14 behavioural
--   cases, all passing. That server does not load pg_safeupdate, so the bare
--   DELETE was legal there and illegal in the only place that matters. Same
--   shape of miss as the CI shim that wrote extension files to the runner
--   instead of the postgres service container: the harness and the real
--   environment differed in exactly the way the change depended on.
--
--   Guard for next time: grep new migrations for
--       ^\s*(DELETE FROM|UPDATE) [a-z_]+\s*;
--   before pushing. Both offenders here match that pattern exactly, and
--   nothing else in 726 or 727 does.
--
-- Only the two function bodies change; everything else in 727 stands.
-- Idempotent. Safe to re-run.

CREATE OR REPLACE FUNCTION public.save_timesheet_entry(
  p_header_id  uuid,
  p_entry_id   uuid,
  p_entry      jsonb,
  p_activities jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header   RECORD;
  v_type     RECORD;
  v_existing RECORD;
  v_proj_id  uuid;
  v_type_id  uuid;
  v_kind     text;
  v_date     date;
  v_total    integer;
  v_names    text[];
  v_itemised boolean := false;
  v_id       uuid;
  r          RECORD;
  v_n        integer := 0;
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

  -- The gap this closes: the day panel used to write to timesheet_entries
  -- directly, and neither RLS nor any trigger checks the header's status. An
  -- approved timesheet could be edited by any caller that skipped the UI.
  IF v_header.status <> 'to_be_submitted' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
      'message', 'This timesheet is no longer editable.');
  END IF;

  v_type_id := NULLIF(p_entry->>'time_type_id','')::uuid;

  SELECT id, name, category, requires_project INTO v_type
  FROM time_types WHERE id = v_type_id AND is_active;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_TIME_TYPE',
      'message', 'Select a valid time type.');
  END IF;

  v_proj_id := NULLIF(p_entry->>'project_id','')::uuid;
  v_kind    := CASE WHEN v_type.category = 'absence' THEN 'leave' ELSE 'time_type' END;

  IF v_type.requires_project AND v_proj_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_REQUIRED',
      'message', 'This time type requires a project.');
  END IF;
  IF NOT v_type.requires_project THEN
    v_proj_id := NULL;
  END IF;

  -- The date is fixed by the row on edit. The day panel edits within one day;
  -- letting a payload move an entry to another date would slip past every
  -- day-scoped rule already checked for the original date.
  IF p_entry_id IS NOT NULL THEN
    SELECT id, header_id, entry_date, is_system_generated INTO v_existing
    FROM timesheet_entries WHERE id = p_entry_id;

    IF NOT FOUND OR v_existing.header_id <> p_header_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ENTRY_NOT_FOUND',
        'message', 'That entry no longer exists.');
    END IF;
    IF v_existing.is_system_generated THEN
      RETURN jsonb_build_object('ok', false, 'error', 'SYSTEM_ROW',
        'message', 'This entry is maintained by another module and cannot be edited here.');
    END IF;
    v_date := v_existing.entry_date;
  ELSE
    v_date := NULLIF(p_entry->>'entry_date','')::date;
    IF v_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'NO_DATE',
        'message', 'A date is required.');
    END IF;
    IF date_trunc('month', v_date)::date <> v_header.period THEN
      RETURN jsonb_build_object('ok', false, 'error', 'OUTSIDE_PERIOD',
        'message', 'Attendance can only be recorded inside this timesheet month.');
    END IF;
    IF v_date > CURRENT_DATE THEN
      RETURN jsonb_build_object('ok', false, 'error', 'FUTURE_DATE',
        'message', 'Attendance cannot be recorded in advance.');
    END IF;
  END IF;

  -- ── Resolve the duration ────────────────────────────────────────────────
  v_itemised := v_type.requires_project
                AND jsonb_typeof(p_activities) = 'array'
                AND jsonb_array_length(p_activities) > 0;

  IF v_itemised THEN
    -- Fold duplicates by name, summing. One pass, so the totals and the name
    -- list cannot disagree with what actually gets inserted below.
    CREATE TEMP TABLE IF NOT EXISTS _tea_in (
      name text, minutes integer, ord integer) ON COMMIT DROP;
    -- TRUNCATE, not DELETE: Supabase loads pg_safeupdate, which rejects any
    -- DELETE with no WHERE clause -- including one against a scratch temp
    -- table. TRUNCATE is not covered by that guard and says what is meant.
    TRUNCATE _tea_in;

    -- GROUP BY the LOWERED name only. Grouping by both the lowered and the
    -- original spelling defeats the whole point: "Testing" and "testing" land
    -- in different groups and then collide on ux_tea_entry_activity. Keep the
    -- casing the user typed FIRST as the surviving label.
    INSERT INTO _tea_in (name, minutes, ord)
    SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord)
    FROM (
      SELECT  btrim(e.value->>'name')            AS name,
              COALESCE((e.value->>'minutes')::integer, 0) AS minutes,
              e.ordinality                        AS ord
      FROM jsonb_array_elements(p_activities) WITH ORDINALITY AS e(value, ordinality)
    ) x
    WHERE x.name <> ''
    GROUP BY lower(x.name);

    IF NOT EXISTS (SELECT 1 FROM _tea_in) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ACTIVITY_REQUIRED',
        'message', 'At least one activity is required for project time.');
    END IF;

    IF EXISTS (SELECT 1 FROM _tea_in WHERE minutes <= 0) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ACTIVITY_DURATION',
        'message', 'Every activity needs a duration greater than 0.');
    END IF;

    SELECT sum(minutes), array_agg(name ORDER BY ord) INTO v_total, v_names FROM _tea_in;
  ELSE
    IF v_type.requires_project THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ACTIVITY_REQUIRED',
        'message', 'At least one activity is required for project time.');
    END IF;
    v_total := COALESCE((p_entry->>'hours_minutes')::integer, 0);
    v_names := NULL;
  END IF;

  IF v_total IS NULL OR v_total <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_DURATION',
      'message', 'Duration must be greater than 0.');
  END IF;

  -- ── Write. Parent first so the child rows have something to hang off; the
  --    parent already carries the correct total and name list, so mig 721's
  --    rule (e) and mig 726's rules (f)/(g) all see the real values. ────────
  IF p_entry_id IS NULL THEN
    INSERT INTO timesheet_entries
      (header_id, entry_date, entry_kind, time_type_id, project_id,
       hours_minutes, notes, activities, created_by)
    VALUES
      (p_header_id, v_date, v_kind, v_type_id, v_proj_id, v_total,
       NULLIF(btrim(COALESCE(p_entry->>'notes','')), ''), v_names, auth.uid())
    RETURNING id INTO v_id;
  ELSE
    v_id := p_entry_id;
    UPDATE timesheet_entries
       SET entry_kind    = v_kind,
           time_type_id  = v_type_id,
           project_id    = v_proj_id,
           hours_minutes = v_total,
           notes         = NULLIF(btrim(COALESCE(p_entry->>'notes','')), ''),
           activities    = v_names,
           updated_at    = now()
     WHERE id = v_id;
  END IF;

  -- Replace the rows wholesale. Inside one transaction this is atomic, which is
  -- the entire reason this lives in an RPC rather than the browser.
  DELETE FROM timesheet_entry_activities WHERE entry_id = v_id;

  IF v_itemised THEN
    FOR r IN SELECT name, minutes, ord FROM _tea_in ORDER BY ord LOOP
      v_n := v_n + 1;
      INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
      VALUES (v_id, r.name, r.minutes, v_n);
    END LOOP;
  END IF;

  PERFORM recalc_timesheet_recorded_minutes(p_header_id);

  RETURN jsonb_build_object('ok', true, 'entry_id', v_id,
                            'hours_minutes', v_total, 'activities', COALESCE(v_n, 0));

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

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
  v_absent    date[] := '{}';
  v_appendd   date[] := '{}';
  v_legacy    date[] := '{}';
  v_created   date[] := '{}';
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_mins      integer;
  v_type      RECORD;
  v_proj      RECORD;
  v_proj_id   uuid;
  v_type_id   uuid;
  v_kind      text;
  v_label     text;
  v_planned   integer;
  v_leave_min integer;
  v_att_cnt   integer;
  v_existing  uuid;
  v_sysgen    boolean;
  v_itemised  boolean := false;
  v_names     text[];
  r           RECORD;
  v_n         integer;
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

  v_type_id := (p_entry->>'time_type_id')::uuid;

  SELECT id, name, category, requires_project INTO v_type
  FROM time_types WHERE id = v_type_id AND is_active;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_TIME_TYPE',
      'message', 'Select a valid time type.');
  END IF;

  v_proj_id := NULLIF(p_entry->>'project_id','')::uuid;
  v_label   := v_type.name;

  IF v_type.requires_project AND v_proj_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_REQUIRED',
      'message', 'This time type requires a project.');
  END IF;

  -- ── Activities: detect the shape, fold duplicates, derive the duration ───
  CREATE TEMP TABLE IF NOT EXISTS _bulk_acts (
    name text, minutes integer, ord integer) ON COMMIT DROP;
  -- TRUNCATE, not DELETE -- see save_timesheet_entry. pg_safeupdate does not
  -- care that the target is a temp table this transaction just created.
  TRUNCATE _bulk_acts;

  IF jsonb_typeof(p_entry->'activities') = 'array'
     AND jsonb_array_length(p_entry->'activities') > 0 THEN

    IF jsonb_typeof((p_entry->'activities')->0) = 'object' THEN
      v_itemised := v_type.requires_project;
      -- Same fold as save_timesheet_entry: lowered name only, first spelling wins.
      INSERT INTO _bulk_acts (name, minutes, ord)
      SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord)
      FROM (
        SELECT btrim(e.value->>'name') AS name,
               COALESCE((e.value->>'minutes')::integer, 0) AS minutes,
               e.ordinality AS ord
        FROM jsonb_array_elements(p_entry->'activities') WITH ORDINALITY AS e(value, ordinality)
      ) x
      WHERE x.name <> ''
      GROUP BY lower(x.name);

      IF EXISTS (SELECT 1 FROM _bulk_acts WHERE minutes <= 0) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ACTIVITY_DURATION',
          'message', 'Every activity needs a duration greater than 0.');
      END IF;
    ELSE
      INSERT INTO _bulk_acts (name, minutes, ord)
      SELECT btrim(e.value #>> '{}'), NULL, e.ordinality
      FROM jsonb_array_elements(p_entry->'activities') WITH ORDINALITY AS e(value, ordinality)
      WHERE btrim(e.value #>> '{}') <> '';
    END IF;
  END IF;

  SELECT array_agg(name ORDER BY ord) INTO v_names FROM _bulk_acts;

  IF v_itemised THEN
    SELECT sum(minutes) INTO v_mins FROM _bulk_acts;
  ELSE
    v_mins := COALESCE((p_entry->>'hours_minutes')::integer, 0);
  END IF;

  IF v_mins IS NULL OR v_mins <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_DURATION',
      'message', 'Duration must be greater than 0.');
  END IF;

  -- ── Project must exist, be active, and cover every selected date ─────────
  IF v_proj_id IS NOT NULL THEN
    SELECT id, name, active, start_date, end_date INTO v_proj
    FROM projects WHERE id = v_proj_id;

    IF NOT FOUND OR NOT v_proj.active THEN
      RETURN jsonb_build_object('ok', false, 'error', 'PROJECT_INACTIVE',
        'message', 'That project is no longer active.');
    END IF;

    v_label := v_proj.name;

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

  -- ── Classify every date before writing anything ──────────────────────────
  FOREACH v_d IN ARRAY v_dates LOOP
    IF date_trunc('month', v_d)::date <> v_header.period THEN
      v_outside := v_outside || v_d; CONTINUE;
    END IF;

    IF v_d > CURRENT_DATE THEN
      v_ahead := v_ahead || v_d; CONTINUE;
    END IF;

    v_planned := time_planned_minutes_for_date(p_header_id, v_d);

    IF v_planned > 0 THEN
      IF v_kind = 'leave' THEN
        IF v_mins >= v_planned THEN
          SELECT count(*) INTO v_att_cnt FROM timesheet_entries e
           WHERE e.header_id = p_header_id AND e.entry_date = v_d
             AND e.entry_kind NOT IN ('leave','holiday');
          IF v_att_cnt > 0 THEN v_absent := v_absent || v_d; CONTINUE; END IF;
        END IF;
      ELSE
        SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_leave_min FROM timesheet_entries e
         WHERE e.header_id = p_header_id AND e.entry_date = v_d AND e.entry_kind = 'leave';
        IF v_leave_min >= v_planned THEN v_absent := v_absent || v_d; CONTINUE; END IF;
      END IF;
    END IF;

    SELECT e.id, e.is_system_generated INTO v_existing, v_sysgen
    FROM   timesheet_entries e
    WHERE  e.header_id    =  p_header_id
      AND  e.entry_date   =  v_d
      AND  e.time_type_id IS NOT DISTINCT FROM v_type_id
      AND  e.project_id   IS NOT DISTINCT FROM v_proj_id;

    IF v_existing IS NULL THEN
      v_created := v_created || v_d;
    ELSIF v_itemised AND NOT COALESCE(v_sysgen, false) THEN
      -- APPEND only onto an entry that ALREADY has activity rows. An entry
      -- written before this migration has names on the parent and no hours
      -- against them, and there is no honest way to split its total here --
      -- anything this function invents would look precise and be fiction.
      -- Send it back so the employee opens the day and allocates the hours
      -- themselves; the day panel converts a legacy entry on first save.
      IF EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = v_existing) THEN
        v_appendd := v_appendd || v_d;
      ELSE
        v_legacy := v_legacy || v_d;
      END IF;
    ELSE
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

  IF array_length(v_absent, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'DAY_FULLY_ABSENT',
      'dates', to_jsonb(v_absent),
      'message', CASE WHEN v_kind = 'leave'
        THEN 'Attendance is already recorded on one or more of the selected days, so a full-day absence cannot be added to them.'
        ELSE 'Absence already covers the whole planned day on one or more of the selected dates.'
      END);
  END IF;

  IF array_length(v_legacy, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'LEGACY_NEEDS_SPLIT',
      'dates', to_jsonb(v_legacy),
      'message', format('%s was recorded on one or more of these dates before activities carried their own hours. Open the day, save the entry once to split its hours across its activities, then try again.', v_label));
  END IF;

  IF array_length(v_clash, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_EXISTS',
      'dates', to_jsonb(v_clash),
      'message', format('%s is already recorded on one or more of the selected dates.', v_label));
  END IF;

  -- ── Write: creates first, then appends ───────────────────────────────────
  IF array_length(v_created, 1) > 0 THEN
    FOREACH v_d IN ARRAY v_created LOOP
      INSERT INTO timesheet_entries
        (header_id, entry_date, entry_kind, time_type_id, project_id,
         hours_minutes, notes, activities, created_by)
      VALUES
        (p_header_id, v_d, v_kind, v_type_id, v_proj_id, v_mins,
         NULLIF(btrim(COALESCE(p_entry->>'notes','')), ''), v_names, auth.uid())
      RETURNING id INTO v_id;
      v_ids := v_ids || v_id;

      IF v_itemised THEN
        v_n := 0;
        FOR r IN SELECT name, minutes, ord FROM _bulk_acts ORDER BY ord LOOP
          v_n := v_n + 1;
          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
          VALUES (v_id, r.name, r.minutes, v_n);
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  IF array_length(v_appendd, 1) > 0 THEN
    FOREACH v_d IN ARRAY v_appendd LOOP
      SELECT e.id INTO v_id FROM timesheet_entries e
       WHERE e.header_id    =  p_header_id
         AND e.entry_date   =  v_d
         AND e.time_type_id IS NOT DISTINCT FROM v_type_id
         AND e.project_id   IS NOT DISTINCT FROM v_proj_id;

      SELECT COALESCE(max(display_order), 0) INTO v_n
      FROM timesheet_entry_activities WHERE entry_id = v_id;

      FOR r IN SELECT name, minutes, ord FROM _bulk_acts ORDER BY ord LOOP
        v_n := v_n + 1;
        INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
        VALUES (v_id, r.name, r.minutes, v_n)
        ON CONFLICT (entry_id, lower(btrim(activity_name)))
        DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes + EXCLUDED.hours_minutes;
      END LOOP;

      v_ids := v_ids || v_id;
    END LOOP;
  END IF;

  PERFORM recalc_timesheet_recorded_minutes(p_header_id);

  RETURN jsonb_build_object(
    'ok', true,
    'created',  COALESCE(array_length(v_created, 1), 0),
    'appended', COALESCE(array_length(v_appendd, 1), 0),
    'entry_ids', to_jsonb(v_ids),
    'dates', to_jsonb(v_dates)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION public.save_timesheet_entry IS
  'Mig 728: as 727, with the scratch temp table cleared by TRUNCATE -- a bare '
  'DELETE is rejected by pg_safeupdate on Supabase.';
COMMENT ON FUNCTION public.bulk_create_timesheet_entries IS
  'Mig 728: as 727, with the scratch temp table cleared by TRUNCATE -- a bare '
  'DELETE is rejected by pg_safeupdate on Supabase.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification: both bodies must be free of an unqualified DELETE.
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'save_timesheet_entry';
  IF v_src IS NULL OR position('TRUNCATE _tea_in' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: save_timesheet_entry still clears its temp table with DELETE.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'bulk_create_timesheet_entries';
  IF v_src IS NULL OR position('TRUNCATE _bulk_acts' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries still clears its temp table with DELETE.';
  END IF;

  RAISE NOTICE 'Migration 728 verified: both activity RPCs are pg_safeupdate-clean.';
END $$;
