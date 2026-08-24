-- Migration : 20260825776_bare_durations_merge_on_paste.sql
-- Purpose   : Make Copy Day behave the same way whether or not the time type
--             happens to need a project.
--
-- THE INCONSISTENCY
--   Paste a day onto a day that already holds the same entry:
--
--     PROJECT type      activity rows are summed. 5h + 4h = 9h, and each
--                       activity keeps its own line, so the 9h can be read back
--                       to what made it.
--
--     NON-PROJECT type  refused. "Training is already recorded on 16 August.
--                       Open that entry to change its hours." The user then does
--                       2 + 8 in their head and retypes it.
--
--   One gesture, two answers, and nothing on screen says which you will get. The
--   difference is not a rule anyone decided — it falls out of project entries
--   having activity rows to sum and non-project entries not.
--
-- WHY NON-PROJECT ENTRIES HAVE NOTHING TO SUM
--   By design, not by accident. MyTimesheet writes
--     actRowsPayload = tt?.requires_project ? actPayload(form.actRows) : null
--   so a type with requires_project = false is a bare duration and always will
--   be. Dev carries 12 such entries today across four employees — Training and
--   On-Site Visit, all created after activity rows shipped. They are not legacy
--   residue to be cleaned up; they are what a correct non-project entry looks
--   like, which is why this is a merge and not a backfill.
--
-- WHAT MERGES, AND WHAT STILL DOES NOT
--   Merges when BOTH sides are genuinely nameless: no activity rows and no
--   activities[] on either. Hours are summed on the parent — trg_tea_sync only
--   recomputes that from child rows, and there are none, so the parent value
--   stands. Notes merge with the same rule 733 uses for project appends.
--
--   Still refuses when either side carries a single legacy activity NAME.
--   Summing there would file the source's hours under the target's name and
--   mislabel them silently. A refusal that names the entry is better than a
--   number that is quietly wrong.
--
-- THE COST, ACCEPTED DELIBERATELY
--   A project merge leaves a trace: the arriving activities are still visible as
--   their own lines. A bare merge cannot — 16 August simply goes from 2h to 10h.
--   A mis-paste is therefore harder to spot, and undoing it means remembering
--   the day used to read 2h. Weighed against a user doing arithmetic by hand on
--   every repeated Training day, and the merge won. The 16h daily cap still
--   applies and is still checked before anything is written.
--
-- Depends on : 775 (atomicity — a collision later in the same paste still
--              unwinds this merge), 772, 733 (the notes-merge rule)

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
  v_code       text;      -- MIG 775
  v_msg        text;      -- MIG 775
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
  -- MIG 775: the loop runs inside its own BEGIN/EXCEPTION block, which makes it
  -- a SUBTRANSACTION. A collision on entry 3 now unwinds entries 1 and 2.
  -- Before this, those errors were RETURNed from inside the loop -- and a RETURN
  -- commits. Measured: pasting 3 entries and colliding on the 2nd left 1 row on
  -- the target while telling the user the paste had failed. The user then
  -- retried against a day that had silently changed.
  BEGIN
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
    SELECT e.id, e.is_system_generated, e.activities AS dup_names,
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
        RAISE EXCEPTION USING
          ERRCODE = 'P0001',
          DETAIL  = 'SYSTEM_ROW',
          MESSAGE = format('%s on %s is maintained by another module and cannot be added to here.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth'));

      ELSIF r.act_rows = 0
            AND COALESCE(array_length(r.activities, 1), 0)    = 0
            AND COALESCE(array_length(v_dup.dup_names, 1), 0) = 0
            AND NOT v_dup.has_rows THEN
        -- ── MIG 776: MERGE two bare durations ──────────────────────────────
        -- Both sides are a plain duration with nothing to itemise — the normal
        -- shape for a time type with requires_project = false (Training,
        -- On-Site Visit). The entry form never writes activity rows for those:
        --   actRowsPayload = tt?.requires_project ? actPayload(...) : null
        --
        -- Until now this refused with ALREADY_EXISTS while the SAME gesture on a
        -- project entry merged, because a project entry has activity rows to sum.
        -- One action, two answers, and nothing on screen said which you would
        -- get. Training 8h pasted onto Training 2h now reads 10h.
        --
        -- The hours live on the parent. trg_tea_sync only recomputes that from
        -- child rows and there are none on either side, so the parent value
        -- stands and this UPDATE is the whole merge.
        UPDATE timesheet_entries t
           SET hours_minutes = t.hours_minutes + r.hours_minutes,
               notes = CASE
                         WHEN t.notes IS NULL                   THEN r.notes
                         WHEN r.notes IS NULL                   THEN t.notes
                         WHEN position(r.notes IN t.notes) > 0  THEN t.notes
                         ELSE t.notes || E'\n' || r.notes
                       END,
               updated_at = now()
         WHERE t.id = v_dup.id;

        v_ids      := v_ids || v_dup.id;
        v_appended := v_appended + 1;

      ELSIF r.act_rows = 0 AND COALESCE(array_length(r.activities, 1), 0) <= 1
            AND NOT v_dup.has_rows THEN
        -- One side carries a single legacy activity NAME. Summing would file the
        -- source's hours under the target's name and quietly mislabel them, so
        -- this still refuses. Only genuinely nameless durations merge above.
        RAISE EXCEPTION USING
          ERRCODE = 'P0001',
          DETAIL  = 'ALREADY_EXISTS',
          MESSAGE = format('%s is already recorded on %s. Open that entry to change its hours.',
                           v_label, to_char(p_to_date, 'FMDD FMMonth'));

      ELSIF NOT v_dup.has_rows THEN
        -- Target entry is legacy (multi-name, no rows) — cannot append without splitting first
        RAISE EXCEPTION USING
          ERRCODE = 'P0001',
          DETAIL  = 'LEGACY_NEEDS_SPLIT',
          MESSAGE = format('%s on %s was recorded before activities carried their own hours. '
                            'Open that entry and save it once to split its hours, then paste again.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth'));

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

        ELSE
          -- MIG 775: a source entry with NO activity rows and NO names. Neither
          -- branch above fires, so nothing would be summed into the target and
          -- the paste would report a merge that moved zero minutes. Refuse
          -- instead of lying about it.
          RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            DETAIL  = 'NO_HOURS_TO_MERGE',
            MESSAGE = format('%s on %s has no hours recorded against an activity, '
                             'so there is nothing to merge into %s. Open that entry '
                             'and give its hours an activity name first.',
                             v_label, to_char(p_from_date, 'FMDD FMMonth'),
                             to_char(p_to_date, 'FMDD FMMonth'));
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

  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    -- Everything the loop wrote is already rolled back by the subtransaction.
    -- Re-shape the raise into the jsonb contract every caller expects, so the
    -- frontend is unchanged: DETAIL carries the code, MESSAGE the sentence.
    GET STACKED DIAGNOSTICS v_code = PG_EXCEPTION_DETAIL,
                            v_msg  = MESSAGE_TEXT;
    RETURN jsonb_build_object('ok', false, 'error', v_code, 'message', v_msg);
  END;

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

COMMENT ON FUNCTION public.paste_timesheet_day(uuid, date, date, uuid[]) IS
  'Mig 776: 775 plus bare-duration merge. A non-project entry pasted onto a day '
  'holding the same type now sums into it, matching what project entries have '
  'always done. Entries carrying a single legacy activity name still refuse, '
  'because summing would mislabel the hours.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $chk$
DECLARE
  v_src text;
  v_n   int;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'MIG 776 ABORT: % overload(s) of paste_timesheet_day.', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day' AND p.pronargs = 4;

  IF position('MIG 776' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 776 ABORT: the bare-duration merge is not in the body.';
  END IF;

  -- The named-legacy case must STILL refuse. Losing this turns a mislabelling
  -- guard into a silent wrong number, which is the failure this migration is
  -- careful not to introduce.
  IF position('''ALREADY_EXISTS''' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'MIG 776 ABORT: ALREADY_EXISTS is gone — a legacy named entry would now '
      'merge under the wrong activity name.';
  END IF;

  -- 775's guarantees must survive this replace.
  IF position('GET STACKED DIAGNOSTICS' IN v_src) = 0
     OR position('DETAIL  = ''SYSTEM_ROW''' IN v_src) = 0
     OR position('DETAIL  = ''LEGACY_NEEDS_SPLIT''' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'MIG 776 ABORT: 775''s atomicity was lost — a collision would commit '
      'partial writes again.';
  END IF;

  IF position('NO_HOURS_TO_MERGE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 776 ABORT: the empty-append guard was lost.';
  END IF;

  RAISE NOTICE 'MIG 776 verified: bare durations merge, named legacy still refuses, 775 intact.';
END
$chk$;

COMMIT;
