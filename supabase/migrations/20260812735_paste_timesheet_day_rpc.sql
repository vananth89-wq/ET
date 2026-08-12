-- Migration : 20260812735_paste_timesheet_day_rpc.sql
-- Purpose   : Give Copy Day a server-side paste, so a pasted day carries its
--             activity rows and goes through the same gate as every other write.
--
-- WHAT WAS WRONG
--   pasteInto() built plain objects in the browser and inserted them straight
--   into timesheet_entries:
--
--     const rows = clipboard.entries.map(e => ({
--       ..., hours_minutes: e.hours_minutes, notes: e.notes,
--       activities: e.activities,          -- the parent's text[] of NAMES
--     }));
--     await supabase.from('timesheet_entries').insert(rows);
--
--   timesheet_entries.activities is a denormalised list of names that mig 727's
--   trg_tea_sync maintains FROM the child rows. Copying the parent verbatim
--   brought the names across and created no rows at all, so the pasted day held
--   an entry whose hours belonged to nothing:
--
--     PDF   AMPTJ · Code Review · —   · 1h      (source day read "1h 00m · 1h")
--     Panel By Project & Activity: Code Review 1h, "Not itemised" 1h
--
--   Totals stayed right because the browser then called
--   recalc_timesheet_recorded_minutes by hand. Only the breakdown was a lie,
--   which is the kind that survives review.
--
--   Three separate holes, one cause -- the last write path that never moved
--   behind an RPC when 727/728 moved the others:
--     * no activity rows
--     * no header-status check (the stated reason save_timesheet_entry exists)
--     * the empty-day and future-date rules enforced only in the browser
--
-- WHAT THIS DOES
--   paste_timesheet_day(header, from_date, to_date) copies a day server-side, in
--   one transaction, reading the SOURCE's activity rows out of the database
--   rather than trusting whatever the browser had cached. Validates every entry
--   before writing any, the way bulk_create_timesheet_entries does, so a paste
--   either lands whole or not at all.
--
-- THE ONE JUDGEMENT CALL
--   A source entry that is itself legacy -- names on the parent, no rows -- has
--   no rows to copy. Migrations 728 and 733 both refuse to invent a split, and
--   that is right when there are several names and no way to know which hour
--   belonged to which. But with EXACTLY ONE name there is nothing to guess: the
--   entry's whole duration is that activity's duration. So one name is split
--   honestly and carried across; two or more are refused, naming the source day
--   so the employee can go and itemise it.
--
-- Depends on : 726 (unique index), 727 (activity rows, trg_tea_sync),
--              730 (the status guard this uses), 733/734 (its wording)

BEGIN;

CREATE OR REPLACE FUNCTION public.paste_timesheet_day(
  p_header_id uuid,
  p_from_date date,
  p_to_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header  RECORD;
  r         RECORD;
  v_rows    integer;
  v_names   text[];
  v_id      uuid;
  v_ids     uuid[] := '{}';
  v_acts    integer := 0;
  v_created integer := 0;
  v_bad     text;
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

  -- Mig 730's guard, in 734's wording. Copy Day was reaching the table directly
  -- and so had never been held to it.
  IF v_header.status = 'to_be_approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
      'message', 'This timesheet is waiting for approval. Withdraw it first if you need to change it.');
  END IF;

  IF date_trunc('month', p_from_date)::date <> v_header.period
     OR date_trunc('month', p_to_date)::date <> v_header.period THEN
    RETURN jsonb_build_object('ok', false, 'error', 'OUTSIDE_PERIOD',
      'message', 'A day can only be copied within its own timesheet month.');
  END IF;

  IF p_from_date = p_to_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'SAME_DAY',
      'message', 'That is the day you copied from.');
  END IF;

  -- Copy Day stays strictly retrospective whatever a time type's advance-dating
  -- flag says: it carries whichever types the source day held and cannot know
  -- that every one of them allows it. Same reasoning as the client rule it
  -- replaces -- Copy Day takes the narrow option every time.
  IF p_to_date > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'FUTURE_DATE',
      'message', 'Attendance cannot be pasted into a future day.');
  END IF;

  -- Empty days only, and empty means empty -- a holiday or an absence on the
  -- target counts. Enforced here for the first time; it used to be a browser
  -- rule that any other caller could ignore.
  IF EXISTS (SELECT 1 FROM timesheet_entries e
             WHERE e.header_id = p_header_id AND e.entry_date = p_to_date) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'TARGET_NOT_EMPTY',
      'message', 'That day already has entries. A day can only be pasted into an empty day.');
  END IF;

  -- ── Validate every source entry before writing any of them ───────────────
  -- Leave and holidays are not copied: an 8h absence pasted onto a 4h-planned
  -- day would be longer than the day exists, and holidays are the calendar's to
  -- place. System rows belong to whichever module wrote them.
  SELECT count(*) INTO v_rows
  FROM   timesheet_entries e
  WHERE  e.header_id  = p_header_id
    AND  e.entry_date = p_from_date
    AND  e.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(e.is_system_generated, false);

  IF v_rows = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOTHING_TO_COPY',
      'message', 'That day has no attendance to copy.');
  END IF;

  SELECT string_agg(DISTINCT COALESCE(pr.name, tt.name), ', ')
    INTO v_bad
  FROM   timesheet_entries e
  LEFT   JOIN projects   pr ON pr.id = e.project_id
  LEFT   JOIN time_types tt ON tt.id = e.time_type_id
  WHERE  e.header_id  = p_header_id
    AND  e.entry_date = p_from_date
    AND  e.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(e.is_system_generated, false)
    AND  NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = e.id)
    AND  COALESCE(array_length(e.activities, 1), 0) > 1;

  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'LEGACY_NEEDS_SPLIT',
      'dates', to_jsonb(ARRAY[p_from_date]),
      'message', format('%s on %s lists several activities but no hours against them, so there is no '
                        'way to know how to divide it. Open %s, save that entry once to split its '
                        'hours, then copy the day again.',
                        v_bad, to_char(p_from_date, 'FMDD FMMonth'), to_char(p_from_date, 'FMDD FMMonth')));
  END IF;

  -- ── Write ────────────────────────────────────────────────────────────────
  FOR r IN
    SELECT e.id, e.entry_kind, e.time_type_id, e.project_id, e.hours_minutes,
           e.notes, e.activities,
           (SELECT count(*) FROM timesheet_entry_activities a WHERE a.entry_id = e.id) AS act_rows
    FROM   timesheet_entries e
    WHERE  e.header_id  = p_header_id
      AND  e.entry_date = p_from_date
      AND  e.entry_kind NOT IN ('leave', 'holiday')
      AND  NOT COALESCE(e.is_system_generated, false)
    ORDER  BY e.created_at, e.id
  LOOP
    -- The name list must be on the parent AT INSERT: mig 721's rule (e) reads it
    -- there, and trg_tea_sync only catches up once the child rows exist.
    IF r.act_rows > 0 THEN
      SELECT array_agg(a.activity_name ORDER BY a.display_order, a.id)
        INTO v_names
      FROM   timesheet_entry_activities a WHERE a.entry_id = r.id;
    ELSE
      v_names := r.activities;                 -- legacy single name, or NULL
    END IF;

    INSERT INTO timesheet_entries
      (header_id, entry_date, entry_kind, time_type_id, project_id,
       hours_minutes, notes, activities, created_by)
    VALUES
      (p_header_id, p_to_date, r.entry_kind, r.time_type_id, r.project_id,
       r.hours_minutes, r.notes, v_names, auth.uid())
    RETURNING id INTO v_id;

    v_ids     := v_ids || v_id;
    v_created := v_created + 1;

    IF r.act_rows > 0 THEN
      -- Copied from the DATABASE, not from the browser's cache. The bug this
      -- migration fixes is exactly what happens when the client is trusted to
      -- carry a record's children around in memory.
      INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
      SELECT v_id, a.activity_name, a.hours_minutes, a.display_order
      FROM   timesheet_entry_activities a
      WHERE  a.entry_id = r.id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_acts := v_acts + v_rows;

    ELSIF COALESCE(array_length(r.activities, 1), 0) = 1 THEN
      -- One name, one duration, no ambiguity: the whole entry IS that activity.
      -- This is the only split that can be made without inventing anything, and
      -- it stops the paste propagating the very shape it is copying.
      INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
      VALUES (v_id, r.activities[1], r.hours_minutes, 1);
      v_acts := v_acts + 1;
    END IF;
  END LOOP;

  PERFORM recalc_timesheet_recorded_minutes(p_header_id);

  RETURN jsonb_build_object('ok', true, 'created', v_created,
                            'activities', v_acts, 'entry_ids', to_jsonb(v_ids));

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR',
    'message', 'That day could not be pasted and nothing has been changed. '
               'Please try again, and report code ' || SQLSTATE || ' if it persists.',
    'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.paste_timesheet_day(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.paste_timesheet_day(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.paste_timesheet_day IS
  'Mig 735: copies one day''s attendance to another day in the same timesheet, '
  'activity rows included, in a single transaction. Replaces the browser-side '
  'insert that copied the parent''s name array and no rows.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 735 ABORT: paste_timesheet_day was not created.';
  END IF;

  -- The point of the whole migration: the child rows come from the table.
  IF position('FROM   timesheet_entry_activities a' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 735 ABORT: paste_timesheet_day does not read the source activity rows.';
  END IF;

  IF position('''message'', SQLERRM' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 735 ABORT: paste_timesheet_day returns SQLERRM as its user-facing message.';
  END IF;

  -- 734's assertion, repeated. A new function is exactly the place the pre-730
  -- guard gets copied in from an old example.
  IF position('v_header.status <> ''to_be_submitted''' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 735 ABORT: paste_timesheet_day carries the pre-730 status guard.';
  END IF;

  RAISE NOTICE 'MIG 735 verified: paste_timesheet_day copies activity rows from the database.';
END $$;

COMMIT;
