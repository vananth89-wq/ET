-- =============================================================================
-- Migration 824 — an activity name can be billable and not billable on the
--                 same day, and that is two rows
--
-- THE KEY WAS WRONG, NOT THE MERGE RULE
-- ═════════════════════════════════════
-- "Testing" for the client and "Testing" on internal rework are the same word
-- for two different facts. 727 made an activity row unique on
-- (entry_id, lower(btrim(activity_name))) -- one row per NAME per entry -- so
-- the second one had to merge into the first, and 821 then had to decide which
-- flag survived. Every answer to that question is wrong:
--
--   last write wins  invents billable minutes, which reach an invoice
--   AND              never invents, but silently loses the billable half
--   refuse           makes the employee rename a real activity to record it
--
-- There is no good merge rule because the merge should not happen. The natural
-- key is (entry, name, is_billable). Once it is, billable merges with billable,
-- non-billable with non-billable, and the question disappears.
--
-- NULLS NOT DISTINCT IS LOAD-BEARING
--   is_billable is NULL wherever the question did not apply -- Training, support
--   entries, internal projects. NULLs are DISTINCT in a unique index by default,
--   so without this every such row would be exempt from the dedupe 727 exists to
--   provide, and "Training" could be recorded four times on one entry. The
--   codebase already relies on this spelling (mig 726).
--
-- THIS UNDOES PART OF 821, DELIBERATELY
-- ═════════════════════════════════════
-- 821 wrote the flags AFTER the child rows, matching on the lowered name. That
-- was chosen to avoid threading through a fold that 728, 729 and 733 had each
-- rewritten. With two rows sharing a name that match is ambiguous -- and worse,
-- the rows cannot even be inserted, because both would carry NULL and collide
-- on the new index before any UPDATE runs.
--
-- So the flag is threaded through the fold after all, and 821's apply blocks are
-- removed. The fold now groups by (lowered name, billable) rather than by name,
-- which is the same change stated in one more place.
--
-- WHAT 727 WARNED ABOUT
--   727's own header says a per-activity `notes` column "can never be added
--   without dropping this index and reopening the question of what a duplicate
--   name means". This migration is that moment. The question was reopened and
--   answered: a duplicate name with a DIFFERENT billability is not a duplicate.
--   A duplicate name with the same billability still is, and still merges.
--
-- IT ALSO REPAIRS A LIVE BREAKAGE THAT 821 SHIPPED
-- ════════════════════════════════════════════════
-- Threading the flag meant rebuilding both functions locally from their real
-- sources -- 729 for bulk, 733 for save, then 801 and 821 replayed on top --
-- instead of from a stub. Reading the result showed that 821 gave
-- bulk_create_timesheet_entries two references to p_activities, which is
-- save_timesheet_entry's parameter. bulk takes p_entry and reads
-- p_entry->'activities'. plpgsql resolves identifiers inside a SQL statement at
-- RUN time, so 821 deployed green; the failure only appears when somebody mass-
-- creates on a BILLABLE project, and then the whole call rolls back with
-- 'column p_activities does not exist'. Live since 821. Section 2 (0) fixes it,
-- and the verification refuses to pass while either function names a parameter
-- it does not have.
--
-- WHY THIS MIGRATION FAILED ITS FIRST DEPLOY
--   The first version anchored the fold on a literal line copied out of save:
--
--       save    e.ordinality                        AS ord
--       bulk    e.ordinality AS ord
--
--   Same code, different padding, so the anchor matched bulk zero times. The
--   sandbox that was supposed to catch it had been written by hand with both
--   folds given the same shape, so it could not. Every anchor here is now
--   either matched on shape and counted before it is written, or taken verbatim
--   from the migration that actually wrote the line.
--
-- Depends on : 727 (the index), 728, 729, 733 (the folds), 776 (paste), 821
-- =============================================================================

BEGIN;

-- ── 1. The key ───────────────────────────────────────────────────────────────

DROP INDEX IF EXISTS public.ux_tea_entry_activity;

CREATE UNIQUE INDEX IF NOT EXISTS ux_tea_entry_activity
  ON public.timesheet_entry_activities
     (entry_id, lower(btrim(activity_name)), is_billable)
  NULLS NOT DISTINCT;

COMMENT ON INDEX public.ux_tea_entry_activity IS
  'Mig 824: one row per (entry, activity name, billability). "Testing" billable '
  'and "Testing" not billable are two different facts about one day and are two '
  'rows. NULLS NOT DISTINCT because is_billable is NULL wherever the question '
  'did not apply -- without it those rows would escape the dedupe entirely.';


-- ── 2. The flag is written with the row, not applied afterwards ──────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_fn text; v_tmp text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['save_timesheet_entry', 'bulk_create_timesheet_entries']
  LOOP
    SELECT count(*) INTO v_hits
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 824: % has % overloads, expected 1.', v_fn, v_hits;
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF position('v_bill_applies' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824: mig 821 must run first -- % does not know about billability at all.', v_fn;
    END IF;
    IF position('billable boolean' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 824: % already threads the flag. Nothing to do.', v_fn;
      CONTINUE;
    END IF;

    v_tmp := CASE WHEN v_fn = 'save_timesheet_entry' THEN '_tea_in' ELSE '_bulk_acts' END;
    v_new := v_src;

    -- (0) 821 SHIPPED A REFERENCE TO A PARAMETER THAT DOES NOT EXIST HERE.
    --
    --     Its refusal and its apply were written for save_timesheet_entry,
    --     which takes p_activities, and the same text was used for
    --     bulk_create_timesheet_entries, which does not: bulk takes p_entry and
    --     reads p_entry->'activities'. plpgsql resolves identifiers inside a
    --     SQL statement at RUN time, not at CREATE time, so 821 deployed
    --     cleanly and nothing failed -- until somebody mass-creates on a
    --     BILLABLE project, where the very first of the two raises
    --     'column p_activities does not exist' and the whole call rolls back.
    --     Two consequences, both live since 821: Mass Create is broken on
    --     billable projects, and BILLABLE_REQUIRED has never once been enforced
    --     on that path.
    --
    --     Found by rebuilding this function locally from 729 + 801 + 821 and
    --     reading the result, rather than from a stub written by hand. A stub
    --     matches its own anchors by construction and would have shown nothing.
    --
    --     Skipped, not failed, if a later migration has already corrected it.
    IF position('p_activities' IN v_new) > 0
       AND position('p_activities' IN pg_get_function_identity_arguments(
             (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = v_fn))) = 0 THEN
      SELECT count(*) INTO v_hits
      FROM   regexp_matches(v_new, 'COALESCE\(p_activities, ''\[\]''::jsonb\)', 'g');
      IF v_hits <> 2 THEN
        RAISE EXCEPTION 'MIG 824: % names p_activities and has no such parameter, but in % place(s), not the 2 that mig 821 wrote. Look before replacing.', v_fn, v_hits;
      END IF;
      v_new := replace(v_new,
        'COALESCE(p_activities, ''[]''::jsonb)',
        'COALESCE(p_entry->''activities'', ''[]''::jsonb)');
      IF position('p_activities' IN v_new) > 0 THEN
        RAISE EXCEPTION 'MIG 824: % still names p_activities somewhere. It would fail at run time.', v_fn;
      END IF;
      RAISE NOTICE 'MIG 824: repaired 821''s reference to a p_activities parameter that % does not have.', v_fn;
    END IF;

    -- (a) The scratch table carries it. Matched on shape: the column list has
    --     been written by 728, 729 and 733 and the whitespace differs.
    v_new := regexp_replace(v_new,
      '(CREATE TEMP TABLE IF NOT EXISTS ' || v_tmp || '[ \t]*\([ \t\n]*name text, minutes integer, ord integer)\)',
      E'\\1, billable boolean)');
    IF position('billable boolean' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: could not widen % in %.', v_tmp, v_fn;
    END IF;

    -- (b) The fold groups by (name, billability) and carries the answer. Two
    --     rows with the same name and different answers are no longer folded
    --     into one, which is the entire point of this migration.
    --
    --     THE LEGACY SHAPE FIRST. bulk still accepts a plain array of strings
    --     (a name with no duration), and that branch selects THREE values into
    --     the scratch table. Widen the column list without widening this and
    --     the two no longer agree -- a mismatch plpgsql does not catch at
    --     CREATE time, so nothing would fail until the first bare-name save.
    --     save_timesheet_entry has no such branch; there this is a no-op.
    IF position('e.value #>> ''{}''' IN v_new) > 0 THEN
      v_new := replace(v_new,
        'SELECT btrim(e.value #>> ''{}''), NULL, e.ordinality',
        'SELECT btrim(e.value #>> ''{}''), NULL, e.ordinality, NULL::boolean');
      IF position('e.ordinality, NULL::boolean' IN v_new) = 0 THEN
        RAISE EXCEPTION 'MIG 824: % has a bare-name activity branch and it was not widened. Its INSERT would select one value short.', v_fn;
      END IF;
    END IF;

    v_new := replace(v_new,
      'INSERT INTO ' || v_tmp || ' (name, minutes, ord)',
      'INSERT INTO ' || v_tmp || ' (name, minutes, ord, billable)');
    v_new := replace(v_new,
      'SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord)',
      'SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord), x.billable');

    --     NOT a literal. 729 wrote bulk's fold and 733 rewrote save's, and the
    --     two lines differ in nothing but their padding:
    --
    --         save    e.ordinality                        AS ord
    --         bulk    e.ordinality AS ord
    --
    --     A literal copied from one matches the other zero times. That is not
    --     hypothetical -- it is precisely how this migration failed its first
    --     deploy, after a hand-built sandbox gave both folds the same shape and
    --     so could not see the difference. Match the shape; keep whatever
    --     indentation is actually there, and count before writing.
    SELECT count(*) INTO v_hits
    FROM   regexp_matches(v_new, '\n[ \t]*e\.ordinality[ \t]+AS ord\n', 'g');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 824: the ordinality anchor matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := regexp_replace(v_new,
      '(\n)([ \t]*)(e\.ordinality[ \t]+AS ord)(\n)',
      E'\\1\\2\\3,\n\\2(e.value->>''billable'')::boolean AS billable\\4');

    v_new := replace(v_new, 'GROUP BY lower(x.name);', 'GROUP BY lower(x.name), x.billable;');

    IF position('GROUP BY lower(x.name), x.billable;' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the fold in % still groups by name alone.', v_fn;
    END IF;
    IF position('AS billable' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the fold in % does not read the billable key from the payload.', v_fn;
    END IF;
    IF position('min(x.ord), x.billable' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the fold in % selects the answer but does not carry it out of the subquery.', v_fn;
    END IF;

    -- (c) Every loop over the scratch table selects it.
    SELECT count(*) INTO v_hits
    FROM   regexp_matches(v_new, 'SELECT name, minutes, ord FROM ' || v_tmp, 'g');
    IF v_hits < 1 THEN
      RAISE EXCEPTION 'MIG 824: no loop over % found in %.', v_tmp, v_fn;
    END IF;
    v_new := replace(v_new,
      'SELECT name, minutes, ord FROM ' || v_tmp,
      'SELECT name, minutes, ord, billable FROM ' || v_tmp);

    -- (d) Every child insert writes it, and every ON CONFLICT names the new key.
    v_new := replace(v_new,
      'INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order)' || E'\n',
      'INSERT INTO timesheet_entry_activities (entry_id, activity_name, hours_minutes, display_order, is_billable)' || E'\n');
    v_new := replace(v_new, 'VALUES (v_id, r.name, r.minutes, v_n)', 'VALUES (v_id, r.name, r.minutes, v_n, r.billable)');
    v_new := replace(v_new,
      'ON CONFLICT (entry_id, lower(btrim(activity_name)))',
      'ON CONFLICT (entry_id, lower(btrim(activity_name)), is_billable)');

    IF position('v_n, r.billable)' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: a child insert in % does not write the flag.', v_fn;
    END IF;

    -- (e) 821's post-hoc apply is made inert rather than deleted.
    --
    --     It matched on the lowered name, which is now ambiguous: with two rows
    --     of a pair it would set both to one value, re-creating by hand exactly
    --     what this migration removes. But cutting a multi-line block out of a
    --     function body by pattern is how you remove more than you meant -- a
    --     first attempt here took 2,234 characters where the blocks account for
    --     about 1,560, and the result would not parse.
    --
    --     So it is narrowed instead: it may only fill in a flag the INSERT left
    --     NULL, and after this migration the INSERT never does where the
    --     question applies. One literal edit, and it reads as what it now is.
    v_new := replace(v_new,
      '     WHERE t.entry_id = v_id' || E'\n',
      '     WHERE t.entry_id = v_id' || E'\n' ||
      '       -- mig 824: inert. The INSERT writes the flag now; this may only' || E'\n' ||
      '       -- fill a gap it left, and it leaves no gaps where the question' || E'\n' ||
      '       -- applies. Matching on name alone can no longer flatten a pair.' || E'\n' ||
      '       AND t.is_billable IS NULL' || E'\n');
    v_new := replace(v_new,
      '     WHERE t.entry_id = ANY(v_ids)' || E'\n',
      '     WHERE t.entry_id = ANY(v_ids)' || E'\n' ||
      '       -- mig 824: inert, as above.' || E'\n' ||
      '       AND t.is_billable IS NULL' || E'\n');

    IF position('mig 824: inert' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: could not narrow 821''s apply in %. It would flatten both rows of a pair.', v_fn;
    END IF;

    -- (f) But its REFUSAL must not go. That is the mandatory rule.
    IF position('BILLABLE_REQUIRED' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the unanswered-activity refusal was removed from % along with the apply.', v_fn;
    END IF;
    IF position('v_bill_applies := v_proj_id IS NOT NULL' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the applicability test was removed from %.', v_fn;
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'MIG 824: % now writes the flag with the row.', v_fn;
  END LOOP;
END $mig$;


-- ── 3. Copy Day keys on the new index ────────────────────────────────────────
--
-- Its merge is now between rows that already agree, so the AND that 821 added
-- can never see a disagreement. It is left in place: it costs nothing, and a
-- rule that says what it means is worth more than one line saved.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 824: paste_timesheet_day not found.';
  END IF;
  IF position('a.is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 824: mig 821 must run first -- paste does not carry the flag yet.';
  END IF;

  IF position('lower(btrim(activity_name)), is_billable)' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 824: paste already keys on the new index. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, 'ON CONFLICT (entry_id, lower(btrim(activity_name)))', '')))
              / length('ON CONFLICT (entry_id, lower(btrim(activity_name)))');
    IF v_hits < 1 THEN
      RAISE EXCEPTION 'MIG 824: no ON CONFLICT found in paste_timesheet_day.';
    END IF;
    v_new := replace(v_src,
      'ON CONFLICT (entry_id, lower(btrim(activity_name)))',
      'ON CONFLICT (entry_id, lower(btrim(activity_name)), is_billable)');
    EXECUTE v_new;
    RAISE NOTICE 'MIG 824: paste_timesheet_day now keys on (entry, name, billability) -- % clause(s).', v_hits;
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src  text;
  v_name text;
  v_def  text;
BEGIN
  -- The index is the whole migration. Check the columns AND the null rule.
  SELECT pg_get_indexdef(i.indexrelid) INTO v_def
  FROM   pg_index i JOIN pg_class c ON c.oid = i.indexrelid
  WHERE  c.relname = 'ux_tea_entry_activity';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'MIG 824 FAILED: ux_tea_entry_activity is missing.';
  END IF;
  IF position('is_billable' IN v_def) = 0 THEN
    RAISE EXCEPTION 'MIG 824 FAILED: the index does not include is_billable, so one name is still one row.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                 WHERE c.relname = 'ux_tea_entry_activity' AND i.indnullsnotdistinct) THEN
    RAISE EXCEPTION 'MIG 824 FAILED: the index is NULLS DISTINCT. Every row where the question did not apply would escape the dedupe.';
  END IF;

  -- Both write paths thread it, and neither kept 821's apply.
  FOR v_name, v_src IN
    SELECT p.proname, pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    IF position('billable boolean' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: % does not carry the flag through its fold.', v_name;
    END IF;
    IF position('GROUP BY lower(x.name), x.billable' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the fold in % still groups by name alone, so the two rows would merge.', v_name;
    END IF;
    IF position('v_n, r.billable)' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: a child insert in % does not write the flag.', v_name;
    END IF;
    IF position('mig 824: inert' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: 821''s apply in % is still unrestricted and would flatten both rows of a pair.', v_name;
    END IF;
    -- The rules that must survive.
    IF position('BILLABLE_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the mandatory rule was lost from %.', v_name;
    END IF;
    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the related-project routing (801) was lost from %.', v_name;
    END IF;
    -- save only. bulk_create_timesheet_entries has never carried this refusal:
    -- it derives v_itemised from requires_project and falls through to
    -- INVALID_DURATION when there is nothing to total. 738's own inventory of
    -- surviving rules lists ACTIVITY_REQUIRED under save and not under bulk,
    -- and that inventory is the record of what each function is supposed to
    -- have. Asserting it for both fails an honest function.
    IF v_name = 'save_timesheet_entry' AND position('ACTIVITY_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the at-least-one-activity rule (727/728) was lost from %.', v_name;
    END IF;
    IF v_name = 'bulk_create_timesheet_entries' AND position('INVALID_DURATION' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the duration refusal was lost from %.', v_name;
    END IF;
  END LOOP;

  -- Neither write path names a parameter it does not have. 821 did -- it gave
  -- bulk save's p_activities -- and because plpgsql resolves that at run time
  -- it deployed green and broke Mass Create on every billable project instead.
  IF EXISTS (
    SELECT 1
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
      AND  position('p_activities' IN pg_get_functiondef(p.oid)) > 0
      AND  position('p_activities' IN pg_get_function_identity_arguments(p.oid)) = 0) THEN
    RAISE EXCEPTION 'MIG 824 FAILED: a write path still refers to a p_activities parameter it does not have.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';
  IF position('lower(btrim(activity_name)), is_billable)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 824 FAILED: paste still infers the old index and would fail at run time.';
  END IF;
  IF position('related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 824 FAILED: paste lost the related project (802).';
  END IF;

  RAISE NOTICE 'Migration 824 verified: one row per (entry, name, billability) with NULLS NOT DISTINCT, the flag written with the row, 821''s ambiguous apply removed, and its refusal kept.';
END $mig$;

COMMIT;
