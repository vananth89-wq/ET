-- Migration : 20260812736_restore_729_allows_future.sql
-- Purpose   : Restore migration 729's allows_future check to save_timesheet_entry,
--             which 733 reverted, and stop this happening a third time.
--
-- WHAT HAPPENED, AGAIN
--   733 rebuilt save_timesheet_entry with CREATE OR REPLACE from migration 728's
--   file. 728 predates both 729 and 730, and both of those had patched the live
--   function body in place -- so no file anywhere held its real definition. The
--   rebuild silently dropped BOTH later rules:
--
--     730's status guard    -> restored by 734
--     729's allows_future   -> this migration
--
--   734 fixed the one I had just been shown and asserted only that one. Same
--   narrowness twice: checking the thing I touched instead of everything the
--   file I copied was missing.
--
-- WHAT IT BROKE
--   save_timesheet_entry went back to 728's blanket rule:
--
--     IF v_date > CURRENT_DATE THEN ... 'Attendance cannot be recorded in advance.'
--
--   so the DAY PANEL refused every future date regardless of the type, while the
--   Create modal still honoured the flag -- bulk_create_timesheet_entries was
--   patched in place and kept it. Training and On-Site Visit both carry
--   allows_future in Dev today: bookable through Create, refused in the panel.
--   Third instance of the same two-buttons-disagree symptom this week, all three
--   from the same rebuild.
--
--   The trigger was never wrong. enforce_timesheet_entry_rules rule (h) reads the
--   flag correctly; save_timesheet_entry just returned FUTURE_DATE before the
--   INSERT could ever reach it.
--
-- ON THE FLAG ITSELF
--   allows_future is NOT gated to a category. The question it asks is "is this
--   SCHEDULED", which cuts across both: Training next Tuesday is as legitimately
--   forward-dated as planned leave, while project work and sick leave can only be
--   reported after the fact. 729's own header says so, upsert_time_type does not
--   gate it, and TimeTypes.tsx offers it for either category -- unlike
--   requires_project (attendance only) and allows_half_day (absence only).
--
--   An earlier draft of 729 DID gate it to absence, and the line comment beside
--   the check still says so. That comment is corrected here too: it contradicts
--   the behaviour, and it is what sent me down the wrong path when I read it.
--
-- Depends on : 729 (the rule this restores), 733 (which reverted it), 734

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — restore the rule
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched from the live body. The file is not the source of truth for this
-- function and has not been since 729 -- which is the whole lesson of 734 and
-- of this migration.

DO $$
DECLARE
  v_src   text;
  v_new   text;
  v_sel   text := 'SELECT id, name, category, requires_project INTO v_type';
  v_blk   text := '    IF v_date > CURRENT_DATE THEN'                                  || E'\n' ||
                  '      RETURN jsonb_build_object(''ok'', false, ''error'', ''FUTURE_DATE'','   || E'\n' ||
                  '        ''message'', ''Attendance cannot be recorded in advance.'');' || E'\n' ||
                  '    END IF;';
  v_hits  integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 736: save_timesheet_entry not found.';
  END IF;

  IF position('allows_future' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 736: save_timesheet_entry already honours allows_future. Nothing to do.';
    RETURN;
  END IF;

  -- The type row has to carry the flag before anything can read it.
  v_hits := (length(v_src) - length(replace(v_src, v_sel, ''))) / length(v_sel);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 736: expected exactly 1 time_types SELECT in save_timesheet_entry, found %.', v_hits;
  END IF;
  v_new := replace(v_src, v_sel,
                   'SELECT id, name, category, requires_project, allows_future INTO v_type');

  v_hits := (length(v_new) - length(replace(v_new, v_blk, ''))) / length(v_blk);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 736: expected exactly 1 blanket future block in save_timesheet_entry, '
                    'found %. It has been reworded -- resolve by hand rather than guessing.', v_hits;
  END IF;

  v_new := replace(v_new, v_blk,
    '    -- MIG 729, restored by 736: the TYPE decides, not the category. The'      || E'\n' ||
    '    -- question is whether the thing is SCHEDULED -- Training next Tuesday'    || E'\n' ||
    '    -- qualifies exactly as planned leave does; project work and sick leave'   || E'\n' ||
    '    -- can only be reported after the fact. Gated nowhere: upsert_time_type'   || E'\n' ||
    '    -- sets it on either category and TimeTypes.tsx offers it on both.'        || E'\n' ||
    '    IF v_date > CURRENT_DATE AND NOT COALESCE(v_type.allows_future, false) THEN' || E'\n' ||
    '      RETURN jsonb_build_object(''ok'', false, ''error'', ''FUTURE_DATE'','    || E'\n' ||
    '        ''message'', format(''%s cannot be recorded in advance.'', v_type.name));' || E'\n' ||
    '    END IF;');

  EXECUTE v_new;
  RAISE NOTICE 'MIG 736: save_timesheet_entry honours allows_future again.';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — correct the stale comment in bulk_create, best effort
-- ═══════════════════════════════════════════════════════════════════════════
-- bulk_create_timesheet_entries never lost the CHECK, but it may still carry the
-- line comment from 729's first draft, which says the flag is absence-only. That
-- comment is now false, and a false comment beside correct code is how the wrong
-- rule gets reintroduced by whoever reads it next. Not asserted: if the wording
-- has moved on, leaving it alone is the right outcome.

DO $$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'bulk_create_timesheet_entries';

  v_new := replace(v_src,
    '-- MIG 729: the type decides. Attendance never; an absence type may opt in.',
    '-- MIG 729: the type decides, on either category. "Is this scheduled?" --'
      || E'\n' || '    -- Training qualifies as much as planned leave (comment fixed in 736).');

  IF v_new <> v_src THEN
    EXECUTE v_new;
    RAISE NOTICE 'MIG 736: corrected the stale absence-only comment in bulk_create_timesheet_entries.';
  ELSE
    RAISE NOTICE 'MIG 736: no stale comment found in bulk_create_timesheet_entries.';
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — assert EVERY rule that lives in save_timesheet_entry
-- ═══════════════════════════════════════════════════════════════════════════
-- The actual defect behind 734 and 736 is not either missing rule. It is that a
-- rebuild drops whatever it does not know about, and each fix so far has only
-- asserted its own contribution. This block lists every rule migrations 726-735
-- put into that function, so the next rebuild fails here instead of shipping.
--
-- ADD TO THIS LIST when a migration adds a rule to save_timesheet_entry. That
-- instruction is the point of the block.

DO $$
DECLARE
  v_src     text;
  v_missing text[] := '{}';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF position('v_header.status = ''to_be_approved''' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 730/734: approved months editable, pending ones not'; END IF;

  IF position('allows_future' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 729/736: allows_future honoured per time type'; END IF;

  IF position('ON CONFLICT (entry_id, lower(btrim(activity_name)))' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: same-name activity rows summed on append'; END IF;

  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: legacy entry refused rather than guessed at'; END IF;

  IF position('ALREADY_EXISTS' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 733: duplicate (day, type, project) named, not leaked'; END IF;

  IF position('ACTIVITY_REQUIRED' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 727/728: project time must be itemised'; END IF;

  IF position('OUTSIDE_PERIOD' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 728: entry must fall inside the header period'; END IF;

  IF position('SYSTEM_ROW' IN v_src) = 0 THEN
    v_missing := v_missing || 'mig 728: system-generated rows not editable here'; END IF;

  -- Negative checks: things that must NOT be there.
  IF position('v_header.status <> ''to_be_submitted''' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: the pre-730 status guard is back'; END IF;

  IF position('''message'', SQLERRM' IN v_src) > 0 THEN
    v_missing := v_missing || 'REGRESSION: SQLERRM returned as the user-facing message'; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 736 ABORT: save_timesheet_entry is missing rules it should carry:\n  - %',
      array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 736 verified: save_timesheet_entry carries all ten checked rules.';
END $$;

COMMIT;
