-- Migration : 20260807729_time_types_allows_future.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: "Nothing is recorded in advance" becomes a real rule, and an
--              admin-controlled exception for absence types.
--
-- THE PROBLEM
--   The rule existed in two places and neither was the database: the Create
--   modal greyed future dates, and bulk_create returned FUTURE_DATE. The DAY
--   PANEL did neither -- selecting tomorrow still offered "Add Attendance", and
--   the only thing stopping the write was a check inside save_timesheet_entry
--   that fires after the form has been filled in. No trigger looked at the date
--   at all, so any direct API call could write work for next month.
--
-- THE SHAPE OF THE EXCEPTION
--   The question is not "did this happen yet" but "is this SCHEDULED". That cuts
--   across both categories, so unlike the two flags before it, allows_future is
--   deliberately NOT gated to a category:
--
--       requires_project   attendance only   (mig 715)
--       allows_half_day    absence only      (mig 718)
--       allows_future      EITHER, per type  (this one)
--
--   Vj's examples, which are the reason it is shaped this way:
--
--       Sick Leave        absence     NO   -- you cannot be ill on a schedule
--       Training          attendance  YES  -- a booked course next Tuesday is a fact
--       Work on a project attendance  NO   -- you cannot have worked tomorrow
--
--   So it is one checkbox on every time type, and the admin decides. Do not
--   "helpfully" force it off for attendance: that would break Training, which is
--   exactly the case this exists for.
--
-- WORTH KNOWING BEFORE ANYONE TURNS IT ON
--   Approved future leave ALREADY reaches the timesheet without this flag: the
--   leave module writes its rows with is_system_generated = true, and those are
--   exempt at the top of enforce_timesheet_entry_rules. Setting allows_future on
--   a leave type does not enable planned leave -- it enables an employee typing
--   future leave DIRECTLY into their timesheet, bypassing the leave request and
--   whatever approval sits behind it. Default false, deliberately.
--
-- Idempotent. Safe to re-run.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — The flag
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS allows_future boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.time_types.allows_future IS
  'Either category, set per type. true = an employee may record this on a date '
  'later than today. Scheduled things qualify (Training, planned leave); things '
  'that can only be reported after the fact do not (project work, sick leave). '
  'Default false. System-generated rows bypass the rule entirely, so the leave '
  'module is unaffected either way.';

-- No category mirror here, unlike 718's allows_half_day. The flag is meaningful
-- on both sides and every type starts at false, so there is nothing to correct.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — upsert_time_type: gate the third flag to its own category
-- ═══════════════════════════════════════════════════════════════════════════
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

  INSERT INTO time_types (id, name, code, category, allows_half_day, allows_future,
                          is_active, requires_project, created_by)
  VALUES (
    v_id,
    trim(p_data->>'name'),
    upper(trim(p_data->>'code')),
    p_data->>'category',
    -- allows_half_day  → absence only
    CASE WHEN p_data->>'category' = 'absence'
         THEN COALESCE((p_data->>'allows_half_day')::boolean, false)
         ELSE false END,
    -- allows_future    → EITHER category, admin's call (mig 729)
    COALESCE((p_data->>'allows_future')::boolean, false),
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
    allows_half_day  = CASE WHEN EXCLUDED.category = 'absence'    THEN EXCLUDED.allows_half_day  ELSE false END,
    allows_future    = EXCLUDED.allows_future,
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
  'Mig 729: as 718, plus allows_future -- settable on any time type, not gated '
  'to a category, because scheduled attendance (Training) is a real case.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — Rule (h) in the trigger, and the two RPCs consult the flag
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.enforce_timesheet_entry_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_planned   integer;
  v_half      boolean;
  v_needs_prj boolean;
  v_other_abs integer;
  v_other_att integer;
  v_blocking  integer;
  v_leave_min integer;
  v_future    boolean;
BEGIN
  -- System-generated rows (holiday sync, leave module) bypass these rules.
  IF NEW.is_system_generated THEN RETURN NEW; END IF;

  v_planned := time_planned_minutes_for_date(NEW.header_id, NEW.entry_date);

  -- (h) MIG 729 -- nothing an employee types may be dated after today.
  --     Any time type may opt in through time_types.allows_future. The test is
  --     whether the thing is SCHEDULED rather than reported: Training next
  --     Tuesday is a fact worth recording now, project work tomorrow is not.
  --     Not gated to a category -- see the migration header.
  --
  --     System-generated rows never reach this line -- the holiday sync and the
  --     leave module are exempt at the top of this function -- so approved
  --     future leave keeps flowing in regardless of the flag.
  --
  --     INSERT only, matching every other rule added since 721: a row written
  --     before this rule existed must stay editable.
  IF TG_OP = 'INSERT' AND NEW.entry_date > CURRENT_DATE THEN
    SELECT COALESCE(tt.allows_future, false) INTO v_future
    FROM time_types tt WHERE tt.id = NEW.time_type_id;

    IF NOT COALESCE(v_future, false) THEN
      RAISE EXCEPTION 'This cannot be recorded in advance -- % is later than today.', NEW.entry_date
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

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

    -- (f) MIG 726 -- the same rule as (d), stated by DURATION rather than by
    --     type. A half-day-capable type recorded for the whole planned day
    --     leaves no room for work either, and (d) never looked at it because
    --     the entire block above is skipped when allows_half_day is true.
    --     INSERT only -- see the header.
    IF TG_OP = 'INSERT' AND v_planned > 0 AND NEW.hours_minutes >= v_planned THEN
      SELECT count(*) INTO v_other_att
      FROM   timesheet_entries e
      WHERE  e.header_id  = NEW.header_id
        AND  e.entry_date = NEW.entry_date
        AND  e.entry_kind NOT IN ('leave', 'holiday')
        AND  e.id IS DISTINCT FROM NEW.id;
      IF v_other_att > 0 THEN
        RAISE EXCEPTION
          'Attendance is already recorded on this day, so an absence covering the full day (% of % minutes) cannot be added.',
          NEW.hours_minutes, v_planned
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

    -- (g) MIG 726 -- the mirror of (f). Absence already covers the whole
    --     planned day, so there is no room left in it, whatever the leave
    --     type's allows_half_day flag says. INSERT only -- see the header.
    IF TG_OP = 'INSERT' AND v_planned > 0 THEN
      SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_leave_min
      FROM   timesheet_entries e
      WHERE  e.header_id  = NEW.header_id
        AND  e.entry_date = NEW.entry_date
        AND  e.entry_kind = 'leave'
        AND  e.id IS DISTINCT FROM NEW.id;
      IF v_leave_min >= v_planned THEN
        RAISE EXCEPTION
          'Absence already covers the whole planned day (% of % minutes), so attendance cannot be added.',
          v_leave_min, v_planned
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

    -- (e) project time must name at least one activity. INSERT only -- mig 721.
    IF TG_OP = 'INSERT' THEN
      SELECT COALESCE(tt.requires_project, false) INTO v_needs_prj
      FROM time_types tt WHERE tt.id = NEW.time_type_id;

      IF COALESCE(v_needs_prj, false)
         AND (NEW.activities IS NULL
              OR array_length(NEW.activities, 1) IS NULL
              OR NOT EXISTS (SELECT 1 FROM unnest(NEW.activities) a WHERE btrim(a) <> '')) THEN
        RAISE EXCEPTION 'At least one activity is required for project time.'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

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

  SELECT id, name, category, requires_project, allows_future INTO v_type
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
    -- MIG 729: the type decides. Attendance never; an absence type may opt in.
    IF v_date > CURRENT_DATE AND NOT COALESCE(v_type.allows_future, false) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'FUTURE_DATE',
        'message', format('%s cannot be recorded in advance.', v_type.name));
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

  SELECT id, name, category, requires_project, allows_future INTO v_type
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

    -- MIG 729: the type decides -- see enforce_timesheet_entry_rules rule (h).
    IF v_d > CURRENT_DATE AND NOT COALESCE(v_type.allows_future, false) THEN
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
      'message', format('%s cannot be recorded in advance.', v_type.name));
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

DROP TRIGGER IF EXISTS trg_timesheet_entry_rules ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_rules
  BEFORE INSERT OR UPDATE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_timesheet_entry_rules();

REVOKE ALL ON FUNCTION public.enforce_timesheet_entry_rules() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION public.enforce_timesheet_entry_rules IS
  'Mig 729: rules (a)-(g) unchanged, plus (h) nothing dated after today unless the '
  'time type sets allows_future. INSERT-only; system-generated rows exempt.';
COMMENT ON FUNCTION public.save_timesheet_entry IS
  'Mig 729: as 728, with the future-date check reading time_types.allows_future.';
COMMENT ON FUNCTION public.bulk_create_timesheet_entries IS
  'Mig 729: as 728, with the future-date check reading time_types.allows_future.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_src text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='time_types'
                   AND column_name='allows_future') THEN
    RAISE EXCEPTION 'ABORT: time_types.allows_future not added.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='enforce_timesheet_entry_rules';
  IF v_src IS NULL OR position('(h) MIG 729' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: rule (h) is not in enforce_timesheet_entry_rules.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='upsert_time_type';
  IF v_src IS NULL OR position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: upsert_time_type does not handle allows_future.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='save_timesheet_entry';
  IF v_src IS NULL OR position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: save_timesheet_entry does not consult allows_future.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='bulk_create_timesheet_entries';
  IF v_src IS NULL OR position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries does not consult allows_future.';
  END IF;

  RAISE NOTICE 'Migration 729 verified: allows_future settable on any type, rule (h) in force, both RPCs consulting it.';
END $$;
