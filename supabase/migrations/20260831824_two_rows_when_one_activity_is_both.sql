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
-- NULLS NOT DISTINCT IS LOad-BEARING
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
    v_new := replace(v_new,
      'INSERT INTO ' || v_tmp || ' (name, minutes, ord)',
      'INSERT INTO ' || v_tmp || ' (name, minutes, ord, billable)');
    v_new := replace(v_new,
      'SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord)',
      'SELECT (array_agg(x.name ORDER BY x.ord))[1], sum(x.minutes)::integer, min(x.ord), x.billable');
    v_new := replace(v_new,
      '              e.ordinality                        AS ord',
      '              e.ordinality                        AS ord,' || E'\n' ||
      '              (e.value->>''billable'')::boolean    AS billable');
    v_new := replace(v_new, 'GROUP BY lower(x.name);', 'GROUP BY lower(x.name), x.billable;');

    IF position('GROUP BY lower(x.name), x.billable;' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the fold in % still groups by name alone.', v_fn;
    END IF;
    IF position('AS billable' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 824: the fold in % does not read the billable key from the payload.', v_fn;
    END IF;

    -- (c) Every loop over the scratch table selects it.
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
  v_src text;
  v_def text;
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
  FOR v_src IN
    SELECT pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    IF position('billable boolean' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: a write path does not carry the flag through its fold.';
    END IF;
    IF position('GROUP BY lower(x.name), x.billable' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: a fold still groups by name alone, so the two rows would merge.';
    END IF;
    IF position('v_n, r.billable)' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: a child insert does not write the flag.';
    END IF;
    IF position('mig 824: inert' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: 821''s apply is still unrestricted and would flatten both rows of a pair.';
    END IF;
    -- The rules that must survive.
    IF position('BILLABLE_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the mandatory rule was lost.';
    END IF;
    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the related-project routing (801) was lost.';
    END IF;
    IF position('ACTIVITY_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 824 FAILED: the at-least-one-activity rule (721) was lost.';
    END IF;
  END LOOP;

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
