-- Migration : 20260812733_day_panel_appends_like_bulk.sql
-- Purpose   : Make the day panel behave like the Create modal when a day
--             already holds this project, and stop both of them dropping a
--             note when they append.
--
-- WHAT WAS WRONG
--   Migration 726 made (header, date, time type, project) unique. Migration 728
--   taught bulk_create_timesheet_entries to live with that: it looks for the
--   existing entry and either creates, APPENDS onto it, or refuses with a
--   reason. save_timesheet_entry -- the day panel's RPC -- never learned any of
--   it. It has thirteen named guards and no case for this one, so the INSERT
--   reached the unique index and the raw Postgres text reached the employee:
--
--     duplicate key value violates unique constraint
--     "ux_timesheet_entries_day_type_project"
--
--   Two buttons, the same intent -- "log another hour on AMPTJ today" -- and
--   only one of them worked.
--
-- WHAT THIS DOES
--   PART 1 gives save_timesheet_entry the same three-way outcome 728 gave the
--   bulk path, deliberately reusing its error codes and its wording so the two
--   screens cannot drift apart again:
--
--     no entry yet                      -> create (unchanged)
--     entry exists, has activity rows   -> append, summing same-named rows
--     entry exists, non-project type    -> ALREADY_EXISTS
--     entry exists, no activity rows    -> LEGACY_NEEDS_SPLIT
--     entry exists, system-generated    -> SYSTEM_ROW
--
--   The two refusals are 728's judgement and this migration keeps it. A
--   non-project entry is a bare duration, so merging 1h into 1h leaves a 2h
--   entry and no record of why -- with activity rows the merge is legible on
--   the screen afterwards. And a legacy entry carries names on the parent with
--   no hours against them; 728's comment is the right one:
--
--     there is no honest way to split its total here -- anything this function
--     invents would look precise and be fiction.
--
--   PART 2 fixes something 728 does today: on the append path it writes the
--   activity rows and nothing else, so a note typed into the Create modal is
--   silently discarded whenever the date turns out to be an append. Both paths
--   now keep it -- existing note wins its place, a new note is appended on its
--   own line, neither is thrown away.
--
--   PART 3 stops both functions putting SQLERRM in front of a user. That is how
--   an index name ended up on screen: the duplicate fell through to the
--   catch-all, which passes the database's own words straight to the browser.
--   The text stays available under 'detail' for whoever is debugging.
--
-- NOT CHANGED
--   The unique index. The day-occupancy triggers (migs 718/721/726) -- they are
--   INSERT-scoped on timesheet_entries, and an append writes child rows, so the
--   parent UPDATE that trg_tea_sync performs does not re-run them. That is
--   exactly how the bulk append has behaved since 728.
--
-- Depends on : 726 (the unique index), 727 (activity rows + trg_tea_sync),
--              728 (bulk append, the shape this copies), 730 (edit window)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — save_timesheet_entry: create, append, or say why not
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
  v_dup      RECORD;
  v_proj_id  uuid;
  v_type_id  uuid;
  v_kind     text;
  v_date     date;
  v_total    integer;
  v_names    text[];
  v_itemised boolean := false;
  v_appended boolean := false;
  v_label    text;
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

  -- ═════════════════════════════════════════════════════════════════════════
  -- NEW in 733 — the day already holds this (type, project)
  --
  -- Creation only. On edit the identity of the row is the row itself, and a
  -- caller changing an existing entry's project onto another entry's identity
  -- is asking for two records to be merged into one and the loser deleted --
  -- a different operation with different consequences, so it keeps its
  -- refusal. mirrors bulk_create_timesheet_entries (mig 728) branch for branch.
  -- ═════════════════════════════════════════════════════════════════════════
  IF p_entry_id IS NULL THEN
    v_label := v_type.name ||
               COALESCE(' — ' || (SELECT p.name FROM projects p WHERE p.id = v_proj_id), '');

    SELECT e.id,
           e.is_system_generated,
           EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = e.id) AS has_rows
      INTO v_dup
    FROM   timesheet_entries e
    WHERE  e.header_id    =  p_header_id
      AND  e.entry_date   =  v_date
      AND  e.time_type_id IS NOT DISTINCT FROM v_type_id
      AND  e.project_id   IS NOT DISTINCT FROM v_proj_id;

    IF FOUND THEN
      IF v_dup.is_system_generated THEN
        RETURN jsonb_build_object('ok', false, 'error', 'SYSTEM_ROW',
          'message', format('%s on %s is maintained by another module and cannot be added to here.',
                            v_label, to_char(v_date, 'FMDD FMMonth')));

      ELSIF NOT v_itemised THEN
        -- A bare duration has nothing to itemise, so a merge would read as one
        -- number with no account of where it came from.
        RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_EXISTS',
          'message', format('%s is already recorded on %s. Open that entry to change its hours.',
                            v_label, to_char(v_date, 'FMDD FMMonth')));

      ELSIF NOT v_dup.has_rows THEN
        RETURN jsonb_build_object('ok', false, 'error', 'LEGACY_NEEDS_SPLIT',
          'message', format('%s was recorded on %s before activities carried their own hours. '
                            'Open that entry and save it once to split its hours across its '
                            'activities, then add this.',
                            v_label, to_char(v_date, 'FMDD FMMonth')));

      ELSE
        -- ── APPEND ────────────────────────────────────────────────────────
        v_id       := v_dup.id;
        v_appended := true;

        -- Keep the note. 728 wrote activity rows and nothing else here, so a
        -- note typed on an append was discarded without a word. Existing text
        -- keeps its place, new text goes on its own line, and a repeat of
        -- something already written is not appended twice.
        UPDATE timesheet_entries t
           SET notes = CASE
                         WHEN t.notes IS NULL                THEN n.txt
                         WHEN position(n.txt IN t.notes) > 0 THEN t.notes
                         ELSE t.notes || E'\n' || n.txt
                       END,
               updated_at = now()
          FROM (SELECT NULLIF(btrim(COALESCE(p_entry->>'notes','')), '') AS txt) n
         WHERE t.id = v_id
           AND n.txt IS NOT NULL;

        SELECT COALESCE(max(display_order), 0) INTO v_n
        FROM timesheet_entry_activities WHERE entry_id = v_id;

        FOR r IN SELECT name, minutes, ord FROM _tea_in ORDER BY ord LOOP
          v_n := v_n + 1;
          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
          VALUES (v_id, r.name, r.minutes, v_n)
          -- ux_tea_entry_activity is UNIQUE on (entry_id, lower(btrim(name))),
          -- so an activity the entry already has must be SUMMED, not added a
          -- second time. Without this the append trips the same class of
          -- constraint the whole migration exists to stop leaking.
          ON CONFLICT (entry_id, lower(btrim(activity_name)))
          DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes
                                        + EXCLUDED.hours_minutes;
        END LOOP;

        -- trg_tea_sync (mig 727) has already put the new sum and name list on
        -- the parent and recalculated the header, so read the truth back
        -- rather than reporting what was sent.
        SELECT hours_minutes INTO v_total FROM timesheet_entries WHERE id = v_id;

        RETURN jsonb_build_object('ok', true, 'appended', true, 'entry_id', v_id,
                                  'label', v_label, 'entry_date', v_date,
                                  'hours_minutes', v_total);
      END IF;
    END IF;
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

  RETURN jsonb_build_object('ok', true, 'appended', false, 'entry_id', v_id,
                            'hours_minutes', v_total, 'activities', COALESCE(v_n, 0));

EXCEPTION WHEN OTHERS THEN
  -- Never SQLERRM to the screen. This is the branch that put
  -- ux_timesheet_entries_day_type_project in front of an employee.
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR',
    'message', 'This entry could not be saved and nothing has been changed. '
               'Please try again, and report code ' || SQLSTATE || ' if it persists.',
    'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_timesheet_entry(uuid, uuid, jsonb, jsonb) TO authenticated;

COMMENT ON FUNCTION public.save_timesheet_entry IS
  'Mig 733: day panel entry write. Creates, or appends onto the entry already '
  'holding this (date, time type, project) -- summing same-named activities -- '
  'or refuses with a reason. Mirrors bulk_create_timesheet_entries.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — bulk_create_timesheet_entries: keep the note on append
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place rather than restated. The function is 300 lines and only
-- two of them change; retyping it to alter two would put every other line at
-- risk of a transcription slip for no benefit. pg_get_functiondef returns
-- re-executable SQL, and the hit count is asserted before anything is run --
-- the same approach migration 730 used on the seven write RPCs.

DO $$
DECLARE
  v_src    text;
  v_new    text;
  v_anchor text := 'SELECT COALESCE(max(display_order), 0) INTO v_n';
  v_hits   integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'bulk_create_timesheet_entries';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 733: bulk_create_timesheet_entries not found.';
  END IF;

  -- Already applied? Then this is a re-run and there is nothing to do.
  IF position('MIG 733 note merge' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 733: bulk_create_timesheet_entries already carries the note merge.';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 733: expected exactly 1 append-loop anchor in '
                    'bulk_create_timesheet_entries, found %. Aborting rather than '
                    'guessing where the note merge belongs.', v_hits;
  END IF;

  v_new := replace(v_src, v_anchor,
    'UPDATE timesheet_entries t' || E'\n' ||
    '         SET notes = CASE                              -- MIG 733 note merge' || E'\n' ||
    '                       WHEN t.notes IS NULL                THEN n.txt' || E'\n' ||
    '                       WHEN position(n.txt IN t.notes) > 0 THEN t.notes' || E'\n' ||
    '                       ELSE t.notes || E''\n'' || n.txt' || E'\n' ||
    '                     END,' || E'\n' ||
    '             updated_at = now()' || E'\n' ||
    '        FROM (SELECT NULLIF(btrim(COALESCE(p_entry->>''notes'','''')), '''') AS txt) n' || E'\n' ||
    '       WHERE t.id = v_id AND n.txt IS NOT NULL;' || E'\n\n' ||
    '      ' || v_anchor);

  -- Same leak as PART 1's catch-all, same fix.
  v_new := replace(v_new,
    '''UNEXPECTED_ERROR'', ''message'', SQLERRM)',
    '''UNEXPECTED_ERROR'', ''message'', ''These entries could not be saved and nothing has been changed. Please try again, and report code '' || SQLSTATE || '' if it persists.'', ''detail'', SQLERRM)');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 733: bulk_create_timesheet_entries patched -- note merge on append.';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_save text;
  v_bulk text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_save
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  SELECT pg_get_functiondef(p.oid) INTO v_bulk
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'bulk_create_timesheet_entries';

  IF position('ON CONFLICT (entry_id, lower(btrim(activity_name)))' IN v_save) = 0 THEN
    RAISE EXCEPTION 'MIG 733 ABORT: save_timesheet_entry has no same-name activity merge.';
  END IF;

  IF position('LEGACY_NEEDS_SPLIT' IN v_save) = 0 THEN
    RAISE EXCEPTION 'MIG 733 ABORT: save_timesheet_entry did not pick up the legacy refusal.';
  END IF;

  IF position('MIG 733 note merge' IN v_bulk) = 0 THEN
    RAISE EXCEPTION 'MIG 733 ABORT: bulk_create_timesheet_entries did not take the note merge.';
  END IF;

  -- The whole point was to stop the raw text reaching a person. Neither
  -- function may hand SQLERRM straight to 'message' any more.
  IF position('''message'', SQLERRM' IN v_save) > 0
     OR position('''message'', SQLERRM' IN v_bulk) > 0 THEN
    RAISE EXCEPTION 'MIG 733 ABORT: a function still returns SQLERRM as its user-facing message.';
  END IF;

  RAISE NOTICE 'MIG 733 verified: both write paths append, sum and keep notes.';
END $$;

COMMIT;
