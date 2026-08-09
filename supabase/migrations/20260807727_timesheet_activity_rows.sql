-- Migration : 20260807727_timesheet_activity_rows.sql
-- Project   : Prowess (HRIS / Expense)
-- Description: Per-activity hours. Activity detail moves out of the
--              timesheet_entries.activities text[] column and into a child
--              table, so each activity carries its own duration.
--
-- THE SHAPE, and why it is not negotiable
--
--   Children are the source of truth. timesheet_entries.hours_minutes and
--   timesheet_entries.activities are DERIVED MIRRORS maintained by a trigger.
--   Neither is ever authored -- not by a person, not by the client.
--
--   Keeping `activities` as a mirror is what lets this land without touching
--   anything else: mig 721's "project time must name at least one activity"
--   rule reads NEW.activities on the parent, and every existing reader
--   (reports, exports, getCellLabel, the entry card) keeps working unchanged.
--
--   ALL WRITES GO THROUGH AN RPC. This is forced by the platform, not a
--   preference: supabase-js issues `insert parent` and `insert children` as two
--   HTTP calls, which are TWO TRANSACTIONS. Any rule evaluated at the end of the
--   first one sees zero children and rejects a perfectly good entry.
--
--   For the same reason there are NO DEFERRABLE CONSTRAINT TRIGGERS here. They
--   fire at COMMIT -- after the RPC has returned -- so their failures escape the
--   function's EXCEPTION block entirely and reach the user as a raw 500 with no
--   message. Cross-row validation happens inside the RPC, in the open, where it
--   can produce a sentence someone can act on.
--
-- SCOPE
--   Itemisation applies to PROJECT TIME ONLY (time types with
--   requires_project = true). Leave and non-project attendance keep the plain
--   hours field; extending itemisation to them would tangle with mig 721's
--   half-day rules (c)/(d) for no gain.
--
-- Idempotent. Safe to re-run.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — The child table
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.timesheet_entry_activities (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id      uuid        NOT NULL REFERENCES public.timesheet_entries(id) ON DELETE CASCADE,
  activity_name text        NOT NULL CHECK (btrim(activity_name) <> ''),
  hours_minutes integer     NOT NULL CHECK (hours_minutes > 0),
  display_order smallint    NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tea_entry
  ON public.timesheet_entry_activities (entry_id);

-- One row per activity name per entry. A UNIQUE INDEX rather than a table
-- constraint because the key is an EXPRESSION: "Testing" and "testing" are the
-- same activity to a person, so they must be the same row.
--
-- The consequence, accepted deliberately: a per-activity `notes` column can
-- never be added without dropping this index and reopening the question of what
-- a duplicate name means. If someone proposes one, this comment is the reason
-- to stop and think.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tea_entry_activity
  ON public.timesheet_entry_activities (entry_id, lower(btrim(activity_name)));

COMMENT ON TABLE public.timesheet_entry_activities IS
  'Mig 727: per-activity hours for project time. The source of truth -- '
  'timesheet_entries.hours_minutes and .activities are mirrors maintained by '
  'time_sync_entry_from_activities().';

-- ── RLS: resolve through the parent entry to its header, exactly as
--    timesheet_entries does. DELETE uses the ''edit'' action, not ''delete'':
--    removing an activity row is editing the entry, not deleting attendance.
ALTER TABLE public.timesheet_entry_activities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tea_select" ON public.timesheet_entry_activities;
CREATE POLICY "tea_select" ON public.timesheet_entry_activities
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.id = timesheet_entry_activities.entry_id
      AND  user_can('timesheet', 'view', h.employee_id)));

DROP POLICY IF EXISTS "tea_insert" ON public.timesheet_entry_activities;
CREATE POLICY "tea_insert" ON public.timesheet_entry_activities
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.id = timesheet_entry_activities.entry_id
      AND  user_can('timesheet', 'edit', h.employee_id)));

DROP POLICY IF EXISTS "tea_update" ON public.timesheet_entry_activities;
CREATE POLICY "tea_update" ON public.timesheet_entry_activities
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.id = timesheet_entry_activities.entry_id
      AND  user_can('timesheet', 'edit', h.employee_id)))
  WITH CHECK (EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.id = timesheet_entry_activities.entry_id
      AND  user_can('timesheet', 'edit', h.employee_id)));

DROP POLICY IF EXISTS "tea_delete" ON public.timesheet_entry_activities;
CREATE POLICY "tea_delete" ON public.timesheet_entry_activities
  FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.id = timesheet_entry_activities.entry_id
      AND  user_can('timesheet', 'edit', h.employee_id)));

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — The mirror trigger
--
-- The RPC already writes the correct parent values, so in the normal path this
-- trigger finds nothing to do. It exists as the BACKSTOP: if anything ever
-- touches the child rows by another route, the parent stays true.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.time_sync_entry_from_activities()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id uuid;
  v_sum      integer;
  v_names    text[];
  v_header   uuid;
BEGIN
  v_entry_id := COALESCE(NEW.entry_id, OLD.entry_id);

  SELECT COALESCE(sum(a.hours_minutes), 0),
         array_agg(a.activity_name ORDER BY a.display_order, a.created_at, a.id)
    INTO v_sum, v_names
  FROM   timesheet_entry_activities a
  WHERE  a.entry_id = v_entry_id;

  -- Zero rows means the entry is being deleted (FK CASCADE fires this trigger
  -- on the way out) or an RPC is mid-replace. Never write hours_minutes = 0:
  -- the CHECK forbids it, and the RPC refuses to leave an itemised entry empty.
  IF v_sum > 0 THEN
    UPDATE timesheet_entries
       SET hours_minutes = v_sum,
           activities    = v_names
     WHERE id = v_entry_id
       AND (hours_minutes IS DISTINCT FROM v_sum OR activities IS DISTINCT FROM v_names);
  END IF;

  SELECT header_id INTO v_header FROM timesheet_entries WHERE id = v_entry_id;
  IF v_header IS NOT NULL THEN
    PERFORM recalc_timesheet_recorded_minutes(v_header);
  END IF;

  RETURN NULL;   -- AFTER trigger; return value is ignored
END;
$$;

REVOKE ALL ON FUNCTION public.time_sync_entry_from_activities() FROM PUBLIC;
COMMENT ON FUNCTION public.time_sync_entry_from_activities IS
  'Mig 727: keeps timesheet_entries.hours_minutes and .activities equal to the '
  'sum and list of the entry''s activity rows. Row-level on purpose -- a handful '
  'of rows per entry, and the IS DISTINCT FROM guard makes repeats free.';

DROP TRIGGER IF EXISTS trg_tea_sync ON public.timesheet_entry_activities;
CREATE TRIGGER trg_tea_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.timesheet_entry_activities
  FOR EACH ROW EXECUTE FUNCTION public.time_sync_entry_from_activities();

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — save_timesheet_entry: parent + children, one transaction
--
-- Replaces the day panel's direct table writes. Everything it needs to reject,
-- it rejects here with a sentence, before anything is written.
--
-- p_activities: [{"name": "...", "minutes": 120}, ...] or NULL/[] for
-- non-itemised entries. Duplicate names (case-insensitively) are SUMMED, not
-- rejected -- logging "Testing" twice in one day is a normal thing to do and
-- the total is what matters.
-- ═══════════════════════════════════════════════════════════════════════════
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
    DELETE FROM _tea_in;

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

REVOKE ALL ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) TO authenticated;
COMMENT ON FUNCTION public.save_timesheet_entry IS
  'Mig 727: create or update one timesheet entry together with its activity '
  'rows, in a single transaction. Also the first write path that checks the '
  'header status server-side.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — bulk_create_timesheet_entries: per-activity hours, and APPEND
--
-- p_entry->'activities' now accepts EITHER shape:
--   ["Testing", "Regression"]                        legacy, no per-activity hours
--   [{"name":"Testing","minutes":180}, ...]          itemised
-- so the signature does not change and no other caller breaks.
--
-- APPEND is the point of this migration. A day that already holds this project
-- is no longer a dead end: the new activity rows merge into the existing entry
-- and the parent total grows. That is only safe BECAUSE the rows are visible --
-- the breakdown shows where each block of hours came from and either can be
-- removed. On a non-itemised entry the only possible meaning of "append" is
-- "silently change the number already there", which is a destructive edit
-- wearing a creation's clothes. Those stay ALREADY_EXISTS.
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
  DELETE FROM _bulk_acts;

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

REVOKE ALL ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_create_timesheet_entries(uuid, jsonb, jsonb) TO authenticated;
COMMENT ON FUNCTION public.bulk_create_timesheet_entries IS
  'Mig 727: as 726, plus per-activity hours and APPEND -- a date already holding '
  'this project merges the new activity rows into the existing entry instead of '
  'being refused.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_src text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='timesheet_entry_activities') THEN
    RAISE EXCEPTION 'ABORT: timesheet_entry_activities not created.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname='public' AND indexname='ux_tea_entry_activity') THEN
    RAISE EXCEPTION 'ABORT: ux_tea_entry_activity missing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND c.relname='timesheet_entry_activities'
                   AND c.relrowsecurity) THEN
    RAISE EXCEPTION 'ABORT: RLS not enabled on timesheet_entry_activities.';
  END IF;

  IF (SELECT count(*) FROM pg_policies
      WHERE schemaname='public' AND tablename='timesheet_entry_activities') < 4 THEN
    RAISE EXCEPTION 'ABORT: expected 4 policies on timesheet_entry_activities.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_tea_sync') THEN
    RAISE EXCEPTION 'ABORT: trg_tea_sync missing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='save_timesheet_entry') THEN
    RAISE EXCEPTION 'ABORT: save_timesheet_entry missing.';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='bulk_create_timesheet_entries';
  IF v_src IS NULL OR position('_bulk_acts' IN v_src) = 0 THEN
    RAISE EXCEPTION 'ABORT: bulk_create_timesheet_entries was not replaced by 727.';
  END IF;

  RAISE NOTICE 'Migration 727 verified: activity rows, mirror trigger, save RPC, and APPEND in bulk create.';
END $$;
