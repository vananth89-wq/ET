-- Migration : 20260825746_paste_into_non_empty_selective.sql
-- Purpose   : Two improvements to Copy Day:
--
--   1. SELECTIVE PASTE — accept an optional p_entry_ids filter so the UI can
--      let the user pick which entries from the source day to copy (mig 735
--      always copies every attendance entry on the day).
--
--   2. PASTE INTO NON-EMPTY DAYS — remove the TARGET_NOT_EMPTY block and
--      apply the same collision logic mig 733 gave save_timesheet_entry and
--      bulk_create_timesheet_entries:
--
--        target has same (time_type, project)  → append  (sum activity rows)
--        target has same time_type, no project → ALREADY_EXISTS
--        target has same entry, system-owned   → SYSTEM_ROW
--        target has same entry, legacy/no rows → LEGACY_NEEDS_SPLIT
--        new combination                        → INSERT
--
--      The 16h daily cap (mig 738) is checked AFTER computing all appends and
--      inserts for the target day, and rejects the whole paste if it would
--      breach — same "all or nothing" principle as the rest of the codebase.
--
-- WHAT IS NOT CHANGED
--   • Leave and holidays are still excluded from the copy
--   • System-generated rows on the SOURCE are still skipped
--   • The legacy-source check (multi-name, no rows) still blocks
--   • Cross-month paste still blocked
--   • Future-date paste still blocked (unless every type allows_future — that
--     is mig 737's rule and it is preserved)
--   • The function signature gains one optional parameter; every existing
--     caller that omits it copies all attendance, same as before
--
-- Depends on : 726 (unique index), 727 (tea rows + trg_tea_sync),
--              733 (append logic this mirrors), 735 (function being replaced),
--              737 (allows_future check in paste), 738 (daily cap helpers)

BEGIN;

CREATE OR REPLACE FUNCTION public.paste_timesheet_day(
  p_header_id  uuid,
  p_from_date  date,
  p_to_date    date,
  p_entry_ids  uuid[] DEFAULT NULL   -- NULL = copy all attendance entries
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_header     RECORD;
  r            RECORD;
  v_dup        RECORD;
  v_rows       integer;
  v_names      text[];
  v_id         uuid;
  v_ids        uuid[] := '{}';
  v_acts       integer := 0;
  v_created    integer := 0;
  v_appended   integer := 0;
  v_bad        text;
  v_cap        integer;
  v_soft       integer;
  v_day_prior  integer;
  v_day_new    integer;
  v_incoming   integer := 0;
  v_warn       text;
  v_label      text;
  v_n          integer;
BEGIN
  -- ── Header / permission / status guards (unchanged from mig 735) ─────────
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

  -- ── Future-date guard (mig 737: per-entry allows_future) ─────────────────
  IF p_to_date > CURRENT_DATE THEN
    -- If entry IDs are filtered, check only those entries; otherwise check all.
    IF EXISTS (
      SELECT 1
      FROM   timesheet_entries e
      JOIN   time_types tt ON tt.id = e.time_type_id
      WHERE  e.header_id  = p_header_id
        AND  e.entry_date = p_from_date
        AND  e.entry_kind NOT IN ('leave', 'holiday')
        AND  NOT COALESCE(e.is_system_generated, false)
        AND  (p_entry_ids IS NULL OR e.id = ANY(p_entry_ids))
        AND  NOT COALESCE(tt.allows_future, false)
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'FUTURE_DATE',
        'message', 'One or more of the selected entries cannot be recorded in advance.');
    END IF;
  END IF;

  -- ── Source validation: at least one copyable entry ────────────────────────
  SELECT count(*) INTO v_rows
  FROM   timesheet_entries e
  WHERE  e.header_id  = p_header_id
    AND  e.entry_date = p_from_date
    AND  e.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(e.is_system_generated, false)
    AND  (p_entry_ids IS NULL OR e.id = ANY(p_entry_ids));

  IF v_rows = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOTHING_TO_COPY',
      'message', 'That day has no attendance to copy.');
  END IF;

  -- Legacy entries: multiple names on parent, no child rows. Can't split honestly.
  SELECT string_agg(DISTINCT COALESCE(pr.name, tt.name), ', ')
    INTO v_bad
  FROM   timesheet_entries e
  LEFT   JOIN projects   pr ON pr.id = e.project_id
  LEFT   JOIN time_types tt ON tt.id = e.time_type_id
  WHERE  e.header_id  = p_header_id
    AND  e.entry_date = p_from_date
    AND  e.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(e.is_system_generated, false)
    AND  (p_entry_ids IS NULL OR e.id = ANY(p_entry_ids))
    AND  NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = e.id)
    AND  COALESCE(array_length(e.activities, 1), 0) > 1;

  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'LEGACY_NEEDS_SPLIT',
      'dates', to_jsonb(ARRAY[p_from_date]),
      'message', format('%s on %s lists several activities but no hours against them. '
                        'Open %s, save that entry once to split its hours, then copy the day again.',
                        v_bad, to_char(p_from_date, 'FMDD FMMonth'),
                        to_char(p_from_date, 'FMDD FMMonth')));
  END IF;

  -- ── Pre-flight: compute total minutes that will land on the target day ────
  -- We sum existing target minutes + what each source entry will contribute
  -- (appends sum into existing, inserts add fresh). This lets us reject the
  -- whole batch before writing a single row.

  SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_day_prior
  FROM   timesheet_entries e
  WHERE  e.header_id = p_header_id AND e.entry_date = p_to_date;

  -- Sum of source entries that will be pasted (selected filter applied)
  SELECT COALESCE(sum(e.hours_minutes), 0) INTO v_incoming
  FROM   timesheet_entries e
  WHERE  e.header_id  = p_header_id
    AND  e.entry_date = p_from_date
    AND  e.entry_kind NOT IN ('leave', 'holiday')
    AND  NOT COALESCE(e.is_system_generated, false)
    AND  (p_entry_ids IS NULL OR e.id = ANY(p_entry_ids));

  v_cap     := time_daily_cap_minutes_for_date(p_header_id, p_to_date);
  v_day_new := v_day_prior + v_incoming;

  -- Cap: reject only when the paste genuinely increases the day total beyond
  -- the cap. An append that sums into an already-over-cap day is the same
  -- arithmetic save_timesheet_entry uses.
  IF v_day_new > v_cap AND v_day_new > v_day_prior THEN
    RETURN jsonb_build_object('ok', false, 'error', 'DAILY_CAP',
      'message', format('%s already holds %sh %sm. Pasting this would make %sh %sm, over the %sh daily limit.',
                        to_char(p_to_date, 'FMDD FMMonth'),
                        v_day_prior / 60, lpad((v_day_prior % 60)::text, 2, '0'),
                        v_day_new / 60,   lpad((v_day_new % 60)::text, 2, '0'),
                        v_cap / 60));
  END IF;

  -- Soft line: warn when paste pushes day beyond schedule + 4h
  v_soft := time_daily_soft_minutes_for_date(p_header_id, p_to_date);
  IF v_soft > 0 AND v_day_new > v_soft AND v_day_new > v_day_prior THEN
    v_warn := format('%s will hold %sh %sm, more than 4 hours beyond the scheduled day.',
                     to_char(p_to_date, 'FMDD FMMonth'),
                     v_day_new / 60, lpad((v_day_new % 60)::text, 2, '0'));
  END IF;

  -- ── Write: for each source entry, create or append ────────────────────────
  FOR r IN
    SELECT e.id, e.entry_kind, e.time_type_id, e.project_id, e.hours_minutes,
           e.notes, e.activities,
           (SELECT count(*) FROM timesheet_entry_activities a WHERE a.entry_id = e.id) AS act_rows
    FROM   timesheet_entries e
    WHERE  e.header_id  = p_header_id
      AND  e.entry_date = p_from_date
      AND  e.entry_kind NOT IN ('leave', 'holiday')
      AND  NOT COALESCE(e.is_system_generated, false)
      AND  (p_entry_ids IS NULL OR e.id = ANY(p_entry_ids))
    ORDER  BY e.created_at, e.id
  LOOP
    -- Build the name list for the new/appended entry
    IF r.act_rows > 0 THEN
      SELECT array_agg(a.activity_name ORDER BY a.display_order, a.id)
        INTO v_names
      FROM   timesheet_entry_activities a WHERE a.entry_id = r.id;
    ELSE
      v_names := r.activities;  -- legacy single name, or NULL
    END IF;

    v_label := COALESCE(
      (SELECT tt.name || COALESCE(' — ' || pr.name, '')
       FROM   time_types tt
       LEFT   JOIN projects pr ON pr.id = r.project_id
       WHERE  tt.id = r.time_type_id),
      'Entry');

    -- Check whether the target day already has this (time_type, project)
    SELECT e.id, e.is_system_generated,
           EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = e.id) AS has_rows
      INTO v_dup
    FROM   timesheet_entries e
    WHERE  e.header_id    = p_header_id
      AND  e.entry_date   = p_to_date
      AND  e.time_type_id IS NOT DISTINCT FROM r.time_type_id
      AND  e.project_id   IS NOT DISTINCT FROM r.project_id;

    IF FOUND THEN
      -- Collision: target already has this (type, project)
      IF v_dup.is_system_generated THEN
        RETURN jsonb_build_object('ok', false, 'error', 'SYSTEM_ROW',
          'message', format('%s on %s is maintained by another module and cannot be added to here.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth')));

      ELSIF r.act_rows = 0 AND COALESCE(array_length(r.activities, 1), 0) <= 1 AND
            NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = v_dup.id) THEN
        -- Non-project type existing on target (bare duration) — cannot merge meaningfully
        RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_EXISTS',
          'message', format('%s is already recorded on %s. Open that entry to change its hours.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth')));

      ELSIF NOT v_dup.has_rows THEN
        -- Target entry is legacy (multi-name, no rows) — cannot append without splitting first
        RETURN jsonb_build_object('ok', false, 'error', 'LEGACY_NEEDS_SPLIT',
          'message', format('%s on %s was recorded before activities carried their own hours. '
                            'Open that entry and save it once to split its hours, then paste again.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth')));

      ELSE
        -- ── APPEND: sum activity rows into the existing entry ──────────────
        v_id := v_dup.id;

        -- Merge notes (same logic as mig 733)
        UPDATE timesheet_entries t
           SET notes = CASE
                         WHEN t.notes IS NULL                          THEN r.notes
                         WHEN r.notes IS NULL                          THEN t.notes
                         WHEN position(r.notes IN t.notes) > 0        THEN t.notes
                         ELSE t.notes || E'\n' || r.notes
                       END,
               updated_at = now()
         WHERE t.id = v_id
           AND r.notes IS NOT NULL;

        SELECT COALESCE(max(display_order), 0) INTO v_n
        FROM timesheet_entry_activities WHERE entry_id = v_id;

        IF r.act_rows > 0 THEN
          -- Copy activity rows from source, summing into same-named activities
          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
          SELECT v_id, a.activity_name, a.hours_minutes, v_n + row_number() OVER (ORDER BY a.display_order, a.id)
          FROM   timesheet_entry_activities a
          WHERE  a.entry_id = r.id
          ON CONFLICT (entry_id, lower(btrim(activity_name)))
          DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes
                                        + EXCLUDED.hours_minutes;
          GET DIAGNOSTICS v_rows = ROW_COUNT;
          v_acts := v_acts + v_rows;

        ELSIF COALESCE(array_length(r.activities, 1), 0) = 1 THEN
          -- Legacy single-name: the whole entry IS that activity
          v_n := v_n + 1;
          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
          VALUES (v_id, r.activities[1], r.hours_minutes, v_n)
          ON CONFLICT (entry_id, lower(btrim(activity_name)))
          DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes
                                        + EXCLUDED.hours_minutes;
          v_acts := v_acts + 1;
        END IF;

        -- trg_tea_sync updates the parent's hours_minutes and activities[]
        v_ids      := v_ids || v_id;
        v_appended := v_appended + 1;
      END IF;

    ELSE
      -- ── INSERT: new combination on the target day ─────────────────────────
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
        INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
        SELECT v_id, a.activity_name, a.hours_minutes, a.display_order
        FROM   timesheet_entry_activities a
        WHERE  a.entry_id = r.id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_acts := v_acts + v_rows;

      ELSIF COALESCE(array_length(r.activities, 1), 0) = 1 THEN
        INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)
        VALUES (v_id, r.activities[1], r.hours_minutes, 1);
        v_acts := v_acts + 1;
      END IF;
    END IF;

  END LOOP;

  PERFORM recalc_timesheet_recorded_minutes(p_header_id);

  RETURN jsonb_build_object(
    'ok',       true,
    'created',  v_created,
    'appended', v_appended,
    'activities', v_acts,
    'entry_ids', to_jsonb(v_ids),
    'warning',  v_warn
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR',
    'message', 'That day could not be pasted and nothing has been changed. '
               'Please try again, and report code ' || SQLSTATE || ' if it persists.',
    'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.paste_timesheet_day(uuid, date, date, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.paste_timesheet_day(uuid, date, date, uuid[]) TO authenticated;

-- Keep the old 3-arg signature accessible so any caller that never passes
-- p_entry_ids continues to work without change.
REVOKE ALL ON FUNCTION public.paste_timesheet_day(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.paste_timesheet_day(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.paste_timesheet_day IS
  'Mig 746: extends 735 with selective paste (p_entry_ids filter) and paste '
  'into non-empty days (collision handling: append same project, reject bare '
  'duplicates, reject legacy). Daily cap enforced pre-write.';

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
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day was not created.';
  END IF;

  IF position('p_entry_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day does not carry the selective filter.';
  END IF;

  IF position('TARGET_NOT_EMPTY' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day still has the TARGET_NOT_EMPTY block.';
  END IF;

  IF position('DAILY_CAP' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day does not check the daily cap.';
  END IF;

  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day does not handle legacy entries on the target.';
  END IF;

  IF position('FROM   timesheet_entry_activities a' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 746 ABORT: paste_timesheet_day does not read activity rows from the database.';
  END IF;

  RAISE NOTICE 'MIG 746 verified: selective paste, non-empty target, daily cap, collision handling all present.';
END $$;

COMMIT;
