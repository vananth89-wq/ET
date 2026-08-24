-- Migration : 20260825775_paste_day_is_all_or_nothing.sql
-- Purpose   : Three corrections to paste_timesheet_day (772), two of them
--             measured rather than reasoned.
--
-- 1. A FAILED PASTE LEFT ROWS BEHIND
--    772's collision errors -- SYSTEM_ROW, ALREADY_EXISTS, LEGACY_NEEDS_SPLIT --
--    were RETURNed from inside the write loop. **A RETURN commits.** Only a
--    raised exception unwinds. Reproduced on a scratch Postgres 16 with the
--    same shape (loop, insert, RETURN an error jsonb on iteration 2):
--
--        returned                        -> {"ok": false, "error": "ALREADY_EXISTS"}
--        rows left behind after ok:false -> 1
--        rows left behind after RAISE    -> 0
--
--    So pasting a three-entry day that collides on the second told the user it
--    had failed AND left the first entry on the target. Their retry then ran
--    against a day that had silently changed underneath them -- and hit a
--    different collision, because the row they had just unknowingly created was
--    now in the way.
--
--    772's header claims "all or nothing". That was true of the daily cap, which
--    is computed before the loop, and false of everything decided inside it.
--
--    FIX: the loop runs inside its own BEGIN/EXCEPTION block -- a subtransaction
--    -- and the three collisions RAISE with the code in DETAIL. The handler
--    re-shapes the raise into the identical jsonb the callers already parse, so
--    no frontend change is needed. The pre-loop guards (header, permission,
--    period, future date, source legacy, daily cap) still RETURN: they run
--    before a single row is written, and an exception there would be theatre.
--
-- 2. THE OLD 3-ARG FUNCTION WAS STILL LIVE
--    772 added a 4-arg overload with a DEFAULT and deliberately re-GRANTed the
--    3-arg one from 735, which still blocks non-empty targets. Two functions,
--    same name, different behaviour. I assumed a 3-arg call would silently take
--    the old body; it does not -- Postgres refuses to choose:
--
--        f(1,2,3)              -> ERROR: function f(integer, integer, integer) is not unique
--        f(a=>1, b=>2, c=>3)   -> ERROR: ... is not unique
--        f(a=>1,b=>2,c=>3,d=>NULL) -> resolves
--
--    Masked today only because the frontend always passes p_entry_ids. Any other
--    caller, or a revert of that frontend change, is a hard failure. This is the
--    exact trap the migration conventions warn about: CREATE OR REPLACE does not
--    replace a differently-signed overload (migs 187, 212, 213). Dropped -- the
--    DEFAULT means every 3-argument call still works.
--
-- 3. AN APPEND COULD MOVE ZERO MINUTES AND REPORT SUCCESS
--    In the APPEND branch, `IF act_rows > 0 ... ELSIF array_length(activities)=1`
--    has no ELSE. A source entry with neither -- a bare attendance row, which
--    nothing in the schema forbids -- reaches it when the target already has
--    activity rows. The counter incremented and the user was told "1 merged"
--    while the day was unchanged. Whether such a row exists on any environment
--    is unverified, so this is defensive: it now refuses and says why, rather
--    than reporting a merge that did not happen.
--
-- WHAT IS NOT CHANGED
--   The jsonb contract, every error code, every message, the selective filter,
--   the collision rules, the cap and the soft-line warning. Callers see the same
--   API; they just stop seeing half-finished days.
--
-- Depends on : 772 (the function this corrects), 735, 733, 738

BEGIN;

-- ── 1. Retire the stale 3-arg overload ───────────────────────────────────────
-- Before the replace, so the verification below can assert exactly one remains.
DROP FUNCTION IF EXISTS public.paste_timesheet_day(uuid, date, date);

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
        RAISE EXCEPTION USING
  ERRCODE = 'P0001',
  DETAIL  = 'SYSTEM_ROW',
  MESSAGE = format('%s on %s is maintained by another module and cannot be added to here.',
                            v_label, to_char(p_to_date, 'FMDD FMMonth'));

      ELSIF r.act_rows = 0 AND COALESCE(array_length(r.activities, 1), 0) <= 1 AND
            NOT EXISTS (SELECT 1 FROM timesheet_entry_activities a WHERE a.entry_id = v_dup.id) THEN
        -- Non-project type existing on target (bare duration) — cannot merge meaningfully
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
  'Mig 775: 772 plus atomicity. Collisions raise inside a subtransaction and are '
  're-shaped into the same jsonb contract, so a rejected paste writes nothing. '
  'The 3-arg overload from 735 is dropped -- p_entry_ids defaults to NULL, so a '
  'three-argument call still copies the whole day.';

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
    RAISE EXCEPTION
      'MIG 775 ABORT: % overload(s) of paste_timesheet_day remain — a 3-arg call '
      'resolves to neither and errors with "is not unique"', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day' AND p.pronargs = 4;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 775 ABORT: the 4-arg paste_timesheet_day is gone.';
  END IF;

  -- The three collisions must RAISE, not RETURN. Asserted by code, because a
  -- single one left as a RETURN reintroduces the partial write for that path
  -- only — the hardest kind of regression to notice.
  IF position('DETAIL  = ''SYSTEM_ROW''' IN v_src) = 0
     OR position('DETAIL  = ''ALREADY_EXISTS''' IN v_src) = 0
     OR position('DETAIL  = ''LEGACY_NEEDS_SPLIT''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 775 ABORT: a collision path still RETURNs instead of raising.';
  END IF;

  IF position('GET STACKED DIAGNOSTICS' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'MIG 775 ABORT: no handler to re-shape the raise — callers would get a raw '
      '500 instead of the jsonb they parse.';
  END IF;

  IF position('NO_HOURS_TO_MERGE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 775 ABORT: the empty-append guard is missing.';
  END IF;

  -- The pre-loop guards must still RETURN: they write nothing, and turning them
  -- into raises would cost a subtransaction for no benefit.
  IF position('''error'', ''PERMISSION_DENIED''' IN v_src) = 0
     OR position('''error'', ''DAILY_CAP''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 775 ABORT: a pre-loop guard was lost in the rewrite.';
  END IF;

  RAISE NOTICE 'MIG 775 verified: one overload, collisions raise inside a subtransaction, contract unchanged.';
END
$chk$;

COMMIT;
