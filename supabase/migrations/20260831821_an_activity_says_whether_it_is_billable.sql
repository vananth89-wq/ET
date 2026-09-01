-- =============================================================================
-- Migration 821 — an activity says whether it is billable
--
-- THE PROBLEM
-- ═══════════
-- A ticket on a billable project takes twelve hours: ten exploring it and two
-- writing the fix. Only the two are chargeable. Nothing in Prowess could say so
-- -- billability was a property of the PROJECT, so all twelve hours were
-- billable or none were, and the project is billable, so all twelve were.
--
-- The unit that knows the answer is the ACTIVITY, which the employee already
-- itemises: "Exploration 10h", "Fix 2h" (mig 727). The flag belongs on the row
-- that already names the work.
--
-- WHY NOT ON THE ENTRY
--   ux_timesheet_entries_day_type_project (mig 726) permits one entry per
--   (timesheet, date, time type, project). A billable AMPTJ entry and a
--   non-billable one on the same day cannot both exist. The activity row is not
--   merely the better unit; the entry is not an available one.
--
-- WHEN THE QUESTION APPLIES, AND WHY IT NEEDS NO NEW FLAG
-- ═══════════════════════════════════════════════════════
-- Billable means somebody is paying, and at Prowess a payer means a project. So
-- the question applies exactly when the entry BOOKS to a billable project:
--
--     project_id IS NOT NULL  AND  that project's type is P001
--
-- That single test already excludes everything it should. Support entries
-- (mig 801) name a project but leave project_id NULL by design, so they fall
-- out without being mentioned. Training names no project and falls out. Work on
-- an internal project falls out because P002 is not P001. No second flag on the
-- time type, and no list of exceptions to keep in step with reality.
--
-- NULL MEANS "THE QUESTION DID NOT APPLY"
--   Three states, not two. true and false are answers somebody gave; NULL is
--   the absence of a question. A boolean NOT NULL DEFAULT false could not tell
--   "not billable" from "never asked", and every report reading it would be
--   guessing which it had.
--
-- MANDATORY WHERE IT APPLIES
--   Checked BEFORE anything is written, so a refusal never leaves half an entry
--   behind. An unanswered row is refused by name rather than defaulted, because
--   a default here is a revenue number nobody chose.
--
-- ON A NAME COLLISION THE MERGED ROW IS BILLABLE ONLY IF BOTH WERE
--   Activity rows fold by lowered name (727), and Copy Day merges them (776).
--   Merging "Testing 2h billable" with "testing 3h not billable" has no right
--   answer, so it takes the conservative one: AND, not OR. Losing billable
--   minutes is a smaller error than inventing them, and the second kind reaches
--   an invoice.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   The flags are applied AFTER the child rows are written rather than threaded
--   through the fold that builds them. That fold has been rewritten by 728 and
--   729 and matching its shape from here would mean guessing at it; a keyed
--   UPDATE afterwards cannot miss. Every anchor is asserted to match once.
--
-- Depends on : 726, 727, 728, 729/736, 776, 801
-- =============================================================================

BEGIN;

-- ── 1. The column ────────────────────────────────────────────────────────────

ALTER TABLE public.timesheet_entry_activities
  ADD COLUMN IF NOT EXISTS is_billable boolean;

COMMENT ON COLUMN public.timesheet_entry_activities.is_billable IS
  'Mig 821: whether these minutes are chargeable. NULL means the question did '
  'not apply -- the entry books to no project, or to one that is not billable. '
  'true/false are answers a person gave. Three states on purpose: "not '
  'billable" and "never asked" are different facts.';

-- Reporting reads this per entry; the parent index already covers entry_id.
COMMENT ON TABLE public.timesheet_entry_activities IS
  'Mig 727: per-activity hours for project time. The source of truth -- '
  'timesheet_entries.hours_minutes and .activities are mirrors maintained by '
  'time_sync_entry_from_activities(). Mig 821 adds is_billable per row.';


-- ── 2. The two entry-writing RPCs ────────────────────────────────────────────
--
-- TWO FUNCTIONS, FOUR WRITE PATHS
--   save_timesheet_entry was rewritten by 733 and returns from two places: one
--   that APPENDS to an existing entry and one that CREATES a new one. Both
--   write activity rows, so both need the flags applied, and missing either
--   would leave a whole path silently unflagged -- which a test exercising the
--   other path would never notice.
--
--   bulk_create_timesheet_entries has two loops and accumulates an id in each.
--   One of them does so BEFORE inserting child rows, so applying there would
--   find nothing to update. It gets a single apply after both loops, keyed on
--   every id the call produced.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_fn text;

  -- (a) Decide applicability and refuse an unanswered row, both BEFORE any
  --     write and AFTER mig 801 has routed a support entry's project into
  --     v_rel_id. The order matters: run this first and v_proj_id still holds
  --     the project a support entry NAMED, so support would be asked a question
  --     it must never be asked. The whole 801 routing block is the anchor for
  --     exactly that reason.
  a_chk CONSTANT text :=
'  v_rel_id := NULL;' || E'\n' ||
'  IF COALESCE(v_type.uses_related_project, false) THEN' || E'\n' ||
'    v_rel_id  := v_proj_id;' || E'\n' ||
'    v_proj_id := NULL;' || E'\n' ||
'  END IF;' || E'\n';

  b_chk CONSTANT text :=
'  v_rel_id := NULL;' || E'\n' ||
'  IF COALESCE(v_type.uses_related_project, false) THEN' || E'\n' ||
'    v_rel_id  := v_proj_id;' || E'\n' ||
'    v_proj_id := NULL;' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  -- mig 821. The billable question applies only where somebody is paying, and' || E'\n' ||
'  -- a payer means a project. Support entries leave project_id NULL (801) and' || E'\n' ||
'  -- so fall out of this test without being named by it.' || E'\n' ||
'  v_bill_applies := v_proj_id IS NOT NULL AND EXISTS (' || E'\n' ||
'    SELECT 1 FROM projects p' || E'\n' ||
'    JOIN   picklist_values pv ON pv.id = p.project_type_id' || E'\n' ||
'    WHERE  p.id = v_proj_id AND pv.ref_id = ''P001'');' || E'\n' ||
'' || E'\n' ||
'  -- Refused before anything is written. Defaulting here would put a number' || E'\n' ||
'  -- nobody chose into the billable share.' || E'\n' ||
'  IF v_bill_applies AND EXISTS (' || E'\n' ||
'       SELECT 1 FROM jsonb_array_elements(COALESCE(p_activities, ''[]''::jsonb)) b' || E'\n' ||
'       WHERE  btrim(COALESCE(b.value->>''name'', '''')) <> ''''' || E'\n' ||
'         AND  (b.value->>''billable'') IS NULL) THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''BILLABLE_REQUIRED'',' || E'\n' ||
'      ''message'', ''Say whether each activity is billable before saving.'');' || E'\n' ||
'  END IF;' || E'\n';

  -- (b) The apply, in three indentations for the three places it is needed.
  b_apply CONSTANT text :=
'  -- mig 821. Applied after the child rows exist rather than threaded through' || E'\n' ||
'  -- the fold that builds them: that fold has been rewritten by 728 and 729,' || E'\n' ||
'  -- and matching its shape from here would mean guessing at it.' || E'\n' ||
'  IF v_bill_applies THEN' || E'\n' ||
'    UPDATE timesheet_entry_activities t' || E'\n' ||
'       SET is_billable = (b.value->>''billable'')::boolean' || E'\n' ||
'      FROM jsonb_array_elements(COALESCE(p_activities, ''[]''::jsonb)) b' || E'\n' ||
'     WHERE t.entry_id = v_id' || E'\n' ||
'       AND lower(btrim(t.activity_name)) = lower(btrim(COALESCE(b.value->>''name'', '''')));' || E'\n' ||
'  ELSE' || E'\n' ||
'    UPDATE timesheet_entry_activities t' || E'\n' ||
'       SET is_billable = NULL' || E'\n' ||
'     WHERE t.entry_id = v_id AND t.is_billable IS NOT NULL;' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n';

  a_bulk CONSTANT text :=
'  PERFORM recalc_timesheet_recorded_minutes(p_header_id);' || E'\n';
  b_bulk CONSTANT text :=
'  -- mig 821. One apply for every entry this call produced. The two loops' || E'\n' ||
'  -- insert their child rows at different points and one accumulates its id' || E'\n' ||
'  -- before inserting any, so this is the only point that is after all of them.' || E'\n' ||
'  IF v_bill_applies THEN' || E'\n' ||
'    UPDATE timesheet_entry_activities t' || E'\n' ||
'       SET is_billable = (b.value->>''billable'')::boolean' || E'\n' ||
'      FROM jsonb_array_elements(COALESCE(p_activities, ''[]''::jsonb)) b' || E'\n' ||
'     WHERE t.entry_id = ANY(v_ids)' || E'\n' ||
'       AND lower(btrim(t.activity_name)) = lower(btrim(COALESCE(b.value->>''name'', '''')));' || E'\n' ||
'  ELSE' || E'\n' ||
'    UPDATE timesheet_entry_activities t' || E'\n' ||
'       SET is_billable = NULL' || E'\n' ||
'     WHERE t.entry_id = ANY(v_ids) AND t.is_billable IS NOT NULL;' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  PERFORM recalc_timesheet_recorded_minutes(p_header_id);' || E'\n';

BEGIN
  FOREACH v_fn IN ARRAY ARRAY['save_timesheet_entry', 'bulk_create_timesheet_entries']
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'MIG 821: % not found.', v_fn;
    END IF;

    -- One signature, or none of this is safe. SELECT ... INTO takes whichever
    -- row comes first, so with two overloads this would patch one at random and
    -- leave the other enforcing nothing -- and the half that was missed is the
    -- half nobody tests.
    SELECT count(*) INTO v_hits
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 821: % has % overloads, expected 1. Resolve them before patching.', v_fn, v_hits;
    END IF;
    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821: mig 801 must run first -- the anchor is the routing block it adds to %.', v_fn;
    END IF;

    IF position('v_bill_applies' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 821: % already carries the billable rule. Nothing to do.', v_fn;
      CONTINUE;
    END IF;

    v_new := v_src;

    v_new := regexp_replace(v_new, '(\n[ \t]*v_rel_id[ \t]+uuid;)',
                            E'\\1\n  v_bill_applies boolean;');
    IF position('v_bill_applies boolean;' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 821: could not declare v_bill_applies in %.', v_fn;
    END IF;

    v_hits := (length(v_new) - length(replace(v_new, a_chk, ''))) / length(a_chk);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 821: the routing anchor matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, a_chk, b_chk);

    IF v_fn = 'save_timesheet_entry' THEN
      -- NOT anchored on the text of the return. 733 wrote these lines, 738
      -- rewrote both to slot ''warning'', v_warn into the middle, and anything
      -- later may do the same again. Two attempts at a literal here both missed
      -- on a shape the file could not show me. Match the stable ends instead --
      -- the call and the ''appended'' key -- and keep whatever indentation is
      -- actually there.
      SELECT count(*) INTO v_hits
      FROM   regexp_matches(v_new, 'RETURN jsonb_build_object\(''ok'', true,[^\n]*''appended''', 'g');
      IF v_hits <> 2 THEN
        RAISE EXCEPTION 'MIG 821: expected 2 success returns in %, found %. Both write activity rows and both need the apply.', v_fn, v_hits;
      END IF;

      v_new := regexp_replace(v_new,
                 '(\n)([ \t]*)(RETURN jsonb_build_object\(''ok'', true,[^\n]*''appended'')',
                 E'\\1' || b_apply || E'\\2\\3', 'g');

      SELECT count(*) INTO v_hits
      FROM   regexp_matches(v_new, 'mig 821. Applied after the child rows exist', 'g');
      IF v_hits <> 2 THEN
        RAISE EXCEPTION 'MIG 821: the apply landed % times in %, expected 2.', v_hits, v_fn;
      END IF;
    ELSE
      v_hits := (length(v_new) - length(replace(v_new, a_bulk, ''))) / length(a_bulk);
      IF v_hits <> 1 THEN
        RAISE EXCEPTION 'MIG 821: the recalc anchor matched % times in %, expected 1.', v_hits, v_fn;
      END IF;
      v_new := replace(v_new, a_bulk, b_bulk);
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'MIG 821: % now records whether each activity is billable.', v_fn;
  END LOOP;
END $mig$;


-- ── 3. Copy Day carries the flag ─────────────────────────────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_copy CONSTANT text :=
'          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)' || E'\n' ||
'          SELECT v_id, a.activity_name, a.hours_minutes, v_n + row_number() OVER (ORDER BY a.display_order, a.id)' || E'\n' ||
'          FROM   timesheet_entry_activities a' || E'\n' ||
'          WHERE  a.entry_id = r.id' || E'\n' ||
'          ON CONFLICT (entry_id, lower(btrim(activity_name)))' || E'\n' ||
'          DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes' || E'\n' ||
'                                        + EXCLUDED.hours_minutes;' || E'\n';
  b_copy CONSTANT text :=
'          INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order, is_billable)' || E'\n' ||
'          SELECT v_id, a.activity_name, a.hours_minutes, v_n + row_number() OVER (ORDER BY a.display_order, a.id), a.is_billable' || E'\n' ||
'          FROM   timesheet_entry_activities a' || E'\n' ||
'          WHERE  a.entry_id = r.id' || E'\n' ||
'          ON CONFLICT (entry_id, lower(btrim(activity_name)))' || E'\n' ||
'          DO UPDATE SET hours_minutes = timesheet_entry_activities.hours_minutes' || E'\n' ||
'                                        + EXCLUDED.hours_minutes,' || E'\n' ||
'                        -- mig 821. AND, not OR: merging a billable row with a' || E'\n' ||
'                        -- non-billable one of the same name has no right' || E'\n' ||
'                        -- answer, and inventing billable minutes reaches an' || E'\n' ||
'                        -- invoice while losing them does not. NULL AND NULL is' || E'\n' ||
'                        -- NULL, so a pair that were never asked stay unasked.' || E'\n' ||
'                        is_billable   = timesheet_entry_activities.is_billable' || E'\n' ||
'                                        AND EXCLUDED.is_billable;' || E'\n';

  a_plain CONSTANT text :=
'        INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)' || E'\n' ||
'        SELECT v_id, a.activity_name, a.hours_minutes, a.display_order' || E'\n' ||
'        FROM   timesheet_entry_activities a' || E'\n' ||
'        WHERE  a.entry_id = r.id;' || E'\n';
  b_plain CONSTANT text :=
'        INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order, is_billable)' || E'\n' ||
'        SELECT v_id, a.activity_name, a.hours_minutes, a.display_order, a.is_billable' || E'\n' ||
'        FROM   timesheet_entry_activities a' || E'\n' ||
'        WHERE  a.entry_id = r.id;' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 821: paste_timesheet_day not found.';
  END IF;
  IF position('related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 821: mig 802 must run first.';
  END IF;

  IF position('is_billable' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 821: paste_timesheet_day already carries the flag. Nothing to do.';
  ELSE
    v_new := v_src;

    v_hits := (length(v_new) - length(replace(v_new, a_copy, ''))) / length(a_copy);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 821: the merge-copy anchor matched % times in paste, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_copy, b_copy);

    v_hits := (length(v_new) - length(replace(v_new, a_plain, ''))) / length(a_plain);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 821: the plain-copy anchor matched % times in paste, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_plain, b_plain);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 821: paste_timesheet_day now copies the billable flag.';
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  n     integer;
BEGIN
  -- Three states, not two.
  SELECT count(*) INTO n FROM information_schema.columns
  WHERE table_schema='public' AND table_name='timesheet_entry_activities'
    AND column_name='is_billable' AND is_nullable='YES' AND column_default IS NULL;
  IF n <> 1 THEN
    RAISE EXCEPTION 'MIG 821 FAILED: is_billable must be nullable with no default -- NULL is the third state and a default would erase it.';
  END IF;

  FOR v_src IN
    SELECT pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
    WHERE  n2.nspname='public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    IF position('v_bill_applies' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821 FAILED: a write path does not decide applicability.';
    END IF;
    IF position('BILLABLE_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821 FAILED: a write path does not refuse an unanswered activity.';
    END IF;
    -- The refusal must come before the write, or it commits half an entry.
    IF position('BILLABLE_REQUIRED' IN v_src) > position('INSERT INTO timesheet_entries' IN v_src) THEN
      RAISE EXCEPTION 'MIG 821 FAILED: the refusal is after the INSERT. It must refuse before anything is written.';
    END IF;
    IF position('pv.ref_id = ''P001''' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821 FAILED: applicability does not test the project type.';
    END IF;
    IF position('SET is_billable = NULL' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821 FAILED: a write path does not clear the flag where the question does not apply.';
    END IF;
    -- Everything 801 put there is still there.
    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 821 FAILED: a write path lost the related-project routing (801).';
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname='public' AND p.proname='paste_timesheet_day';

  IF position('a.is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 821 FAILED: Copy Day does not carry the flag.';
  END IF;
  IF position('AND EXCLUDED.is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 821 FAILED: the merge does not combine the flag conservatively.';
  END IF;
  IF position('OR EXCLUDED.is_billable' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 821 FAILED: the merge uses OR. That invents billable minutes.';
  END IF;
  IF position('related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 821 FAILED: paste lost the related project (802).';
  END IF;

  RAISE NOTICE 'Migration 821 verified: is_billable per activity with NULL meaning the question did not apply, refused before the write where it does, cleared where it does not, and carried conservatively by Copy Day.';
END $mig$;

COMMIT;
