-- Migration : 20260812734_restore_730_guard_on_save_entry.sql
-- Purpose   : Put migration 730's status guard back on save_timesheet_entry,
--             which migration 733 reverted, and make that class of revert fail
--             at deploy time instead of on an employee's screen.
--
-- WHAT HAPPENED
--   Migration 730 inverted the status guard on all seven timesheet write RPCs:
--
--     before   IF v_header.status <> 'to_be_submitted'  -- locked out approved
--     after    IF v_header.status =  'to_be_approved'   -- locked out pending
--
--   That inversion IS the feature. Refusing every status except
--   'to_be_submitted' was the thing keeping employees out of their own approved
--   months, and unlocking those months inside the edit window is what 730 was
--   asked to do.
--
--   730 applied it by patching the LIVE function bodies -- pg_get_functiondef,
--   string replace, EXECUTE -- because the alternative was retyping seven long
--   functions to change one line in each. So after 730 the true definition of
--   save_timesheet_entry existed only in the database. No file held it.
--
--   Migration 733 then rebuilt save_timesheet_entry with CREATE OR REPLACE,
--   using migration 728's text as its base. 728 predates 730. The rebuild
--   carried 728's guard and 728's wording back in with it, and 733's own
--   verification block only checked the things 733 added.
--
--   Result on Dev: an approved month inside the edit window refused every save
--   from the day panel with "This timesheet is no longer editable." The Create
--   modal kept working, because 733 patched that one in place rather than
--   recreating it -- so the two buttons disagreed again, in the opposite
--   direction from the bug 733 was written to fix.
--
-- THE GENERAL LESSON, ENCODED BELOW
--   A function patched in place has no file that reflects its real state.
--   Rebuilding it from an older file silently reverts every later patch, and
--   nothing complains. PART 2 makes the assertion permanent rather than a
--   one-off inside 730: from here on, any migration that reintroduces the
--   pre-730 guard anywhere fails its own deploy.
--
-- Depends on : 730 (the guard this restores), 733 (which reverted it)

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — restore the guard
-- ═══════════════════════════════════════════════════════════════════════════
-- Patched in place, from the live body, for exactly the reason above: the file
-- is not the source of truth for this function and never was.

DO $$
DECLARE
  v_src     text;
  v_new     text;
  v_guard   text := 'v_header.status <> ''to_be_submitted''';
  v_oldmsg  text := 'This timesheet is no longer editable.';
  v_hits    integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 734: save_timesheet_entry not found.';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_guard, ''))) / length(v_guard);

  IF v_hits = 0 THEN
    -- Either 730's guard survived (someone fixed it first) or the wording moved
    -- on again. Tell those two apart rather than reporting silence as success.
    IF position('v_header.status = ''to_be_approved''' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 734: save_timesheet_entry already carries the 730 guard. Nothing to do.';
    ELSE
      RAISE EXCEPTION 'MIG 734: save_timesheet_entry carries neither the pre-730 guard nor '
                      '730''s. Its status check has been reworded upstream -- resolve by hand '
                      'rather than letting this migration guess.';
    END IF;
  ELSIF v_hits <> 1 THEN
    RAISE EXCEPTION 'MIG 734: save_timesheet_entry has % pre-730 guards, expected exactly 1.', v_hits;
  ELSE
    v_new := replace(v_src, v_guard, 'v_header.status = ''to_be_approved''');
    v_new := replace(v_new, v_oldmsg,
                     'This timesheet is waiting for approval. Withdraw it first if you need to change it.');

    -- 728's comment above the guard describes the OLD behaviour as the thing
    -- being protected against, which is now backwards. Best-effort: the
    -- migration does not depend on it matching.
    v_new := replace(v_new,
      '-- The gap this closes: the day panel used to write to timesheet_entries'  || E'\n' ||
      '  -- directly, and neither RLS nor any trigger checks the header''s status. An' || E'\n' ||
      '  -- approved timesheet could be edited by any caller that skipped the UI.',
      '-- The gap this closes: the day panel used to write to timesheet_entries'  || E'\n' ||
      '  -- directly, and neither RLS nor any trigger checks the header''s status.' || E'\n' ||
      '  -- Since mig 730 the status that blocks is to_be_approved, not "anything'  || E'\n' ||
      '  -- other than to_be_submitted" -- an approved month inside the edit window'|| E'\n' ||
      '  -- is meant to be editable, and a sheet awaiting an approver is not.');

    EXECUTE v_new;
    RAISE NOTICE 'MIG 734: save_timesheet_entry restored to the 730 guard.';
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — make the revert impossible to ship quietly again
-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 730 asserted this once, at the end of its own run. That caught
-- nothing later, because nothing re-ran it. Repeating it here does not help the
-- NEXT migration either -- so the real value is that any future migration which
-- rebuilds one of these functions from a stale file will fail THIS assertion
-- the moment someone replays the history, and fail its own deploy if it copies
-- this block. It is cheap; the bug it catches cost an afternoon.

DO $$
DECLARE
  v_bad   integer;
  v_names text;
BEGIN
  SELECT count(*), string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_bad, v_names
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  JOIN   pg_language  l ON l.oid = p.prolang
  WHERE  n.nspname = 'public'
    -- prokind 'f' only, and only the languages we write in. pg_get_functiondef
    -- raises on an aggregate ("array_agg is an aggregate function"), so a bare
    -- scan of pg_proc aborts the migration on a schema that has any.
    AND  p.prokind = 'f'
    AND  l.lanname IN ('plpgsql', 'sql')
    AND  position('v_header.status <> ''to_be_submitted''' IN pg_get_functiondef(p.oid)) > 0;

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 734 ABORT: % function(s) still carry the pre-730 status guard: %. '
                    'An approved month inside the edit window would refuse every write.',
                    v_bad, v_names;
  END IF;

  RAISE NOTICE 'MIG 734: no function carries the pre-730 guard.';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — and prove 734 did not do to 733 what 733 did to 730
-- ═══════════════════════════════════════════════════════════════════════════
-- The whole failure was a rebuild that dropped an earlier change without
-- noticing. Asserting only the thing this migration restores would repeat the
-- mistake one layer up.

DO $$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'save_timesheet_entry';

  IF position('ON CONFLICT (entry_id, lower(btrim(activity_name)))' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 734 ABORT: 733''s same-name activity merge is gone from save_timesheet_entry.';
  END IF;
  IF position('LEGACY_NEEDS_SPLIT' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 734 ABORT: 733''s legacy refusal is gone from save_timesheet_entry.';
  END IF;
  IF position('''message'', SQLERRM' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 734 ABORT: save_timesheet_entry returns SQLERRM as its user-facing message again.';
  END IF;
  IF position('v_header.status = ''to_be_approved''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 734 ABORT: the 730 guard did not take.';
  END IF;

  RAISE NOTICE 'MIG 734 verified: 730''s guard and 733''s append both present in save_timesheet_entry.';
END $$;

COMMIT;
