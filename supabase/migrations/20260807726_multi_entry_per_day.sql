-- Migration : 20260807726_multi_entry_per_day.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: Three related changes, all about what a single day may hold.
--
--   1. STATE THE UNIQUENESS RULE. "One entry per day" was never a database
--      rule. There is no unique constraint on timesheet_entries beyond the
--      primary key, and mig 721's trigger already reasons about sibling rows on
--      the same date. The only thing producing one-entry-per-day behaviour is a
--      single line in the React date picker and a matching check in
--      bulk_create_timesheet_entries. The real rule is narrower:
--
--          one entry per (timesheet, date, time type, project)
--
--      so a day may hold 4h on QCC and 4h on Training, but not two QCC rows.
--
--   2. NO ATTENDANCE ON A DAY ALREADY FULLY COVERED BY ABSENCE, and the mirror,
--      NO FULL-DAY ABSENCE ON A DAY THAT ALREADY HAS ATTENDANCE. Mig 721 rules
--      (c) and (d) sit inside `IF NOT COALESCE(allows_half_day, false)`, so a
--      type where that flag is TRUE, recorded for the full planned day, blocks
--      nothing today: 8h leave + 8h work = a 16-hour day that passes the
--      constraint, the trigger, the RPC and the UI alike. These rules are
--      therefore INSTANCE-level -- they read the hours actually recorded, not
--      the type's flag -- which is both what "full day" means in plain language
--      and a superset of (d), since (c) forces a full-day-only leave to equal
--      planned anyway.
--
--   3. SCOPE THE MASS-CREATE CLASH CHECK to the same triple, and pre-classify
--      the absence case so one bad date stops discarding the whole batch.
--
-- INSERT-ONLY, DELIBERATELY. Both new rules are enforced on INSERT and not on
-- UPDATE, for exactly the reason mig 721 gives for its rule (e): rows written
-- before the rule existed must stay editable, or the next save of a legacy
-- 16-hour day is rejected by a rule that did not exist when it was written.
--
-- The gap that leaves, knowingly: insert 1h of work against 4h of leave (legal),
-- then edit it to 8h -- nothing objects. That is over-logging, which the day
-- panel's progress bar surfaces, and at insert time the day genuinely was not
-- full. There is no over-logging cap in this system by decision, not omission.
--
-- Idempotent. Safe to re-run.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0 — Pre-flight
--
-- CREATE UNIQUE INDEX on a table that already contains duplicates fails with a
-- message naming one arbitrary row and nothing else. Count them first and abort
-- with something a human can act on.
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_groups integer;
  v_sample text;
BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN
    RAISE EXCEPTION
      'ABORT: this migration needs PostgreSQL 15+ for UNIQUE ... NULLS NOT DISTINCT (found %).',
      current_setting('server_version');
  END IF;

  SELECT count(*), string_agg(txt, ', ' ORDER BY txt)
    INTO v_groups, v_sample
  FROM (
    SELECT format('%s x%s', e.entry_date, count(*)) AS txt
    FROM   timesheet_entries e
    GROUP  BY e.header_id, e.entry_date, e.time_type_id, e.project_id
    HAVING count(*) > 1
    LIMIT  20
  ) d;

  IF COALESCE(v_groups, 0) > 0 THEN
    RAISE EXCEPTION
      'ABORT: % duplicate (timesheet, date, time type, project) group(s) already exist -- %. '
      'Resolve these before the unique index can be created.',
      v_groups, v_sample;
  END IF;

  RAISE NOTICE 'Migration 726 part 0: no duplicate (timesheet, date, type, project) groups.';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — The uniqueness rule, in the database for the first time
--
-- NULLS NOT DISTINCT is what makes one index cover both shapes: a non-project
-- type (project_id NULL) collapses on (day, type), a project type on
-- (day, type, project). Without it, NULLs compare as distinct and every
-- non-project row would be exempt -- which is precisely the case we most want
-- covered, since that is where "already exists" has no other meaning.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE UNIQUE INDEX IF NOT EXISTS ux_timesheet_entries_day_type_project
  ON public.timesheet_entries (header_id, entry_date, time_type_id, project_id)
  NULLS NOT DISTINCT;

COMMENT ON INDEX public.ux_timesheet_entries_day_type_project IS
  'Mig 726: one entry per (timesheet, date, time type, project). Multiple projects '
  'and multiple attendance types per day are allowed; a second row for the same '
  'project on the same day is not.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — Day occupancy rules in the trigger
--
-- Reproduces mig 721 in full (CREATE OR REPLACE needs the whole body) and adds
-- two rules, marked (f) and (g). Everything from 718/721 is unchanged.
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

REVOKE ALL ON FUNCTION public.enforce_timesheet_entry_rules() FROM PUBLIC;
COMMENT ON FUNCTION public.enforce_timesheet_entry_rules IS
  'Mig 726: 721''s rules (a)-(e) unchanged, plus (f) no full-day absence onto a day '
  'with attendance and (g) no attendance onto a day already fully covered by absence. '
  'Both instance-level (measured in minutes, not by allows_half_day) and INSERT-only.';

-- Trigger definition unchanged; recreated for idempotency.
DROP TRIGGER IF EXISTS trg_timesheet_entry_rules ON public.timesheet_entries;
CREATE TRIGGER trg_timesheet_entry_rules
  BEFORE INSERT OR UPDATE ON public.timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_timesheet_entry_rules();

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — Mass create: clash scoped to the triple, absence pre-classified
--
-- Reproduces mig 720 with two changes to the scope loop. Everything else --
-- permission, status, project validity, the write, the error shapes -- is 720
-- verbatim, so the UI's "Deselect these N dates" affordance keeps working.
--
-- Why pre-classify the absence case rather than let the trigger raise: this
-- function wraps its body in EXCEPTION WHEN OTHERS, which is a subtransaction,
-- so ONE bad date rolls back every date and the user is shown the database's
-- own sentence with no date attached. Returning the offending dates instead
-- lets them drop those days and keep the rest.
-- ═══════════════════════════════════════════════════════════════════════════
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
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_mins      integer;
  v_type      RECORD;
  v_proj      RECORD;
  v_proj_id   uuid;
  v_type_id   uuid;
  v_kind      text;
  -- Never read v_proj outside the branch that populates it: an unassigned
  -- plpgsql RECORD raises "record is not assigned yet" the moment a field is
  -- touched, and this function is reached with no project on every
  -- non-project time type. Carry the display label separately.
  v_label     text;
  v_planned   integer;
  v_leave_min integer;
  v_att_cnt   integer;
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

  -- ── Project must exist, be active, and cover every selected date ──────────
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

  -- ── Remaining scope checks, all dates before any write ────────────────────
  -- Order matters: the cheapest and most absolute first, so the reason the user
  -- is shown is the most useful one. Day occupancy is checked before the triple,
  -- because a full day is a fact about the DAY, not about this entry.
  FOREACH v_d IN ARRAY v_dates LOOP
    IF date_trunc('month', v_d)::date <> v_header.period THEN
      v_outside := v_outside || v_d;
      CONTINUE;
    END IF;

    IF v_d > CURRENT_DATE THEN
      v_ahead := v_ahead || v_d;
      CONTINUE;
    END IF;

    v_planned := time_planned_minutes_for_date(p_header_id, v_d);

    IF v_planned > 0 THEN
      IF v_kind = 'leave' THEN
        -- MIG 726 rule (f): a full-day absence needs an empty-of-work day.
        IF v_mins >= v_planned THEN
          SELECT count(*) INTO v_att_cnt
          FROM   timesheet_entries e
          WHERE  e.header_id  = p_header_id
            AND  e.entry_date = v_d
            AND  e.entry_kind NOT IN ('leave', 'holiday');
          IF v_att_cnt > 0 THEN
            v_absent := v_absent || v_d;
            CONTINUE;
          END IF;
        END IF;
      ELSE
        -- MIG 726 rule (g): attendance needs room left in the day.
        SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_leave_min
        FROM   timesheet_entries e
        WHERE  e.header_id  = p_header_id
          AND  e.entry_date = v_d
          AND  e.entry_kind = 'leave';
        IF v_leave_min >= v_planned THEN
          v_absent := v_absent || v_d;
          CONTINUE;
        END IF;
      END IF;
    END IF;

    -- MIG 726: the clash is now the TRIPLE, not the day. A day may already hold
    -- other projects and other attendance types; only a second row for this
    -- same (type, project) is a duplicate. IS NOT DISTINCT FROM so a NULL
    -- project_id matches a NULL project_id, matching the unique index's
    -- NULLS NOT DISTINCT.
    IF EXISTS (
      SELECT 1 FROM timesheet_entries e
      WHERE  e.header_id    =  p_header_id
        AND  e.entry_date   =  v_d
        AND  e.time_type_id IS NOT DISTINCT FROM v_type_id
        AND  e.project_id   IS NOT DISTINCT FROM v_proj_id
    ) THEN
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

  IF array_length(v_clash, 1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_EXISTS',
      'dates', to_jsonb(v_clash),
      'message', format('%s is already recorded on one or more of the selected dates.', v_label));
  END IF;

  -- ── Write. Any trigger rejection (mig 718/721/726 rules) aborts the lot. ──
  FOREACH v_d IN ARRAY v_dates LOOP
    INSERT INTO timesheet_entries
      (header_id, entry_date, entry_kind, time_type_id, project_id,
       hours_minutes, notes, activities, created_by)
    VALUES
      (p_header_id, v_d, v_kind,
       v_type_id,
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
  'Mig 726: as 720, plus the clash check is scoped to (date, time type, project) '
  'rather than the whole day, and days already fully covered by absence are '
  'returned as DAY_FULLY_ABSENT with their dates instead of aborting the batch.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_src text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public'
                   AND indexname  = 'ux_timesheet_entries_day_type_project') THEN
    RAISE EXCEPTION 'ABORT: ux_timesheet_entries_day_type_project not created.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_timesheet_entry_rules') THEN
    RAISE EXCEPTION 'ABORT: trg_timesheet_entry_rules missing.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'enforce_timesheet_entry_rules';
  IF v_src IS NULL OR position('(g) MIG 726' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: enforce_timesheet_entry_rules does not carry the 726 rules.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'bulk_create_timesheet_entries';
  IF v_src IS NULL OR position('DAY_FULLY_ABSENT' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries was not replaced by 726.';
  END IF;

  RAISE NOTICE 'Migration 726 verified: uniqueness stated, day-occupancy rules (f)+(g) in force, bulk create scoped to the triple.';
END $$;
