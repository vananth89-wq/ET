-- =============================================================================
-- Migration 854 — a back-dated removal says so too
--
-- THE HOLE 852 LEFT
-- ═════════════════
--   852 made the rule: a removal is mentioned on the period that BEGINS on the
--   day the action was taken. It closed that for the two shapes 844 reaches
--   when the removal date is on or after the open-ended period's start. It did
--   not close the third.
--
--   844 CASE 1 -- "the active set starts STRICTLY AFTER p_effective_from" --
--   splits the covering period, CREATES a period beginning on the removal
--   date, and then stamps the marker on the ACTIVE period instead of the one
--   it just made. There the marker has removed_on < effective_from, which 852
--   hides, correctly: that period is the future relative to the removal.
--
--   So the destination exists and is empty, and the record sits somewhere it
--   can never be read. Measured, an employee with a scheduled change and an
--   ordinary removal dated TODAY:
--
--       01 Aug - 30 Sep   PM01, PM02
--       01 Oct - Present  PM01, PM02, PM03      <- scheduled
--
--       remove PM01 effective 23 Sep (today)
--
--       01 Aug - 22 Sep   PM01, PM02
--       23 Sep - 30 Sep   PM02                  <- the day of the action. Silent.
--       01 Oct - Present  PM02, PM03            <- marker here, hidden
--
--   THIS IS NOT THE RARE CASE IT LOOKS LIKE. The branch is chosen by comparing
--   the removal date with the OPEN-ENDED period's start, not with today. Give
--   an employee any scheduled future change -- a perfectly ordinary thing --
--   and every removal dated before it takes this path, including one dated
--   today. It is the shape of the screen this whole thread started from.
--
-- WHAT CHANGES
-- ════════════
--   The ended row is written into the period CASE 1 already creates, carrying
--   removed_on = that period's own effective_from. One insert. The marker on
--   the active period stays exactly where 844 put it -- it is what keeps the
--   manager off the live screen from that date on, and removing it would
--   revoke the removal.
--
--   So the same action now leaves two rows: a hidden one that makes the
--   removal take effect, and a visible one on the day it happened. That is the
--   same division of labour CASE 3 has had since 852.
--
--   844's refusal to walk removals FORWARD through later periods is untouched
--   and stays untouched. That is a real undecidability -- a later row holding
--   the same manager might be the assignment continuing or somebody entering
--   it again, and the data cannot say which. This migration does not guess at
--   it; it only writes down, on one day, what the caller already asked for.
--
-- Depends on: 844 (CASE 1), 851 (provenance), 852 (the rule this completes)
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src  text;
  v_from text;
  v_to   text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 854 FAILED: fn_close_and_replace_job_relationship_set() does not exist.';
  END IF;
  IF position('MIG 852' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: 852 has not been applied -- this completes its rule.';
  END IF;

  IF position('MIG 854' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 854: the retroactive branch already records the day -- skipping.';
  ELSE
    -- Unique to CASE 1: only this branch marks v_old_set while writing a
    -- different set. CASE 2 marks the set it is standing on and CASE 3 marks
    -- the one it closes, and neither carries this comment.
    v_from := '    -- Apply remove_codes to the still-active set: soft-delete instead of hard-delete' || E'\n'
           || '    IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      UPDATE employee_job_relationship_item' || E'\n'
           || '      SET    removed_on = p_effective_from' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL;' || E'\n'
           || '    END IF;';

    v_to   := '    -- ═══ MIG 854: the record of the action, on the day it was taken ═══' || E'\n'
           || '    -- Written FIRST, while the active set still holds the assignment live --' || E'\n'
           || '    -- the UPDATE below is what ends it, and this reads the manager from the' || E'\n'
           || '    -- row it is about to mark.' || E'\n'
           || '    --' || E'\n'
           || '    -- v_new_set_id is the period beginning on the removal date: either the' || E'\n'
           || '    -- one this branch just created by splitting, or an existing one that' || E'\n'
           || '    -- starts on exactly that date (844''s v_exact). Either way the ended row' || E'\n'
           || '    -- carries removed_on = that period''s own effective_from, which is the' || E'\n'
           || '    -- one test 852 applies.' || E'\n'
           || '    --' || E'\n'
           || '    -- ON CONFLICT DO NOTHING: if the period already holds that slot -- live,' || E'\n'
           || '    -- or ended by an earlier action -- it already says what it needs to.' || E'\n'
           || '    IF v_new_set_id IS NOT NULL AND array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, p_effective_from, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL' || E'\n'
           || '      ON CONFLICT DO NOTHING;' || E'\n'
           || '    END IF;' || E'\n'
           || E'\n'
           || '    -- Apply remove_codes to the still-active set: soft-delete instead of hard-delete' || E'\n'
           || '    -- MIG 854: and this stays. It is what keeps the manager off the live' || E'\n'
           || '    -- screen from p_effective_from on; 852 hides it, because relative to the' || E'\n'
           || '    -- active period the removal is in the past. Hidden and load-bearing.' || E'\n'
           || '    IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      UPDATE employee_job_relationship_item' || E'\n'
           || '      SET    removed_on = p_effective_from' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL;' || E'\n'
           || '    END IF;';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 854 FAILED: expected 1 CASE 1 removal block, found %. '
                      'CASE 2 and CASE 3 carry different comments; if this found 0 '
                      'the live text has moved and the anchor needs re-reading.', v_hits;
    END IF;

    EXECUTE replace(v_src, v_from, v_to);
    RAISE NOTICE 'MIG 854: fn_close_and_replace_job_relationship_set patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe bigint;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF position('MIG 854' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the writer did not take the replacement.';
  END IF;
  -- The marker on the active set must SURVIVE. Without it the removal does not
  -- take effect at all, and the test would pass while the feature was gone.
  IF (SELECT count(*) FROM regexp_matches(v_src,
        'SET    removed_on = p_effective_from', 'g')) < 2 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the retroactive branch stopped ending the assignment.';
  END IF;
  -- 844's, 851's and 852's work must all survive: this adds one insert.
  IF position('v_next_from - 1' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the writer lost 844''s next-set bound.';
  END IF;
  IF position('v_exact.id IS NOT NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the writer lost 844''s exact-date branch.';
  END IF;
  IF position('source_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the writer lost 851''s provenance.';
  END IF;
  IF position('MIG 852' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 854 FAILED: the writer lost 852''s day-of-action record.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the new insert against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_item i
  WHERE  i.relationship_code = ANY(ARRAY['PM01'])
    AND  i.removed_on IS NULL
    AND  i.source_project_id IS NOT DISTINCT FROM i.source_project_id;

  RAISE NOTICE 'MIG 854 OK: a back-dated removal is recorded on its day, and still takes effect.';
END $v$;

COMMIT;
