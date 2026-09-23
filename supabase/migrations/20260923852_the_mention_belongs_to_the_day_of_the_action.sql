-- =============================================================================
-- Migration 852 — the mention belongs to the day the action was taken
--
-- THE RULE, AS ASKED FOR
-- ══════════════════════
--   "Only on the day which the action is taken we need to mention, and not in
--    any future or past records."
--
--   Iqraa is removed effective 01 Aug. History should read:
--
--       01 Jul 2026 - 31 Jul 2026   PM01 Iqraa Shaikh, PM02 Mohammed Insaf
--       01 Aug 2026 - 30 Sep 2026   PM02 Mohammed Insaf
--                                   -- ENDED --
--                                   PM01 <struck> Iqraa   Ended 31 Jul 2026
--       01 Oct 2026 (Scheduled)     PM02 Mohammed Insaf
--
--   July is untouched: she WAS the PM01 every day of it. October is silent:
--   she is simply not there. One period carries the mention -- the one that
--   begins on the day of the action.
--
--   In the database that is one test:
--
--       show a removed item iff   removed_on = s.effective_from
--
-- WHAT THIS REPLACES
-- ══════════════════
--   850 put the mention on a period of its own covering the LAST VALID DAY:
--   01 Jul - 30 Jul, then a one-day 31 Jul carrying the strike, then 01 Aug.
--   That answered an earlier reading of the same request. It is narrower now:
--   the day of the ACTION, which is 01 Aug, and that period already exists.
--   Nothing needs splitting, and a period whose only content is a strike is a
--   period nobody asked for -- so 850's pre-pass and its record-day helper
--   come back out.
--
-- WHERE THE WRITER HAS TO PUT IT
-- ══════════════════════════════
--   844 records a removal effective D in one of two shapes:
--
--     CASE 2  a set already begins on D. Mark in place -- 844's original
--             behaviour, which turns out to be exactly right: removed_on =
--             effective_from is the test history now applies. 850 moved this
--             marker to the day before; 852 moves it back.
--
--     CASE 3  no set begins on D, so the active set is closed at D-1 and a new
--             one opens on D. 844 marked the CLOSING set. Under the equals
--             rule that row is invisible -- and invisible is not the same as
--             absent: that period is one the relationship ran through from end
--             to end, so hiding the manager there says she was not the PM01 in
--             July, which is false. The marker leaves that set entirely and an
--             ended row is written into the NEW one instead.
--
--   That second half is the case that caught the first attempt at this. The
--   filter change alone looked right on the period that mattered and quietly
--   deleted a manager from the month before it.
--
--   CASE 1 (retroactive, the active set starts after this date) is untouched.
--   Its marker lands where removed_on < effective_from, which the rule hides:
--   844 declined to walk removals forward and this does not reopen that.
--
--   No new sets are created by any of this.
--
-- Depends on: 844 (the two shapes), 846 (the readers), 850 (whose pre-pass
--             this removes), 851 (provenance, carried onto the ended row)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. History: equals, not greater-than
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_job_relationships_history';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 852 FAILED: get_job_relationships_history() does not exist.';
  END IF;
  IF position('ended_on' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: history has no ended_on -- 850 has not been applied.';
  END IF;

  IF position('MIG 852' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 852: history already tests equals -- skipping.';
  ELSE
    v_from := '        WHERE  i.set_id = s.id' || E'\n'
           || '          -- MIG 846: compared against THIS SET''s start, not against today. An' || E'\n'
           || '          -- item ended 01 Sep was valid for every day of a 01 Jul - 31 Aug set' || E'\n'
           || '          -- and belongs in it; it is not part of a set beginning 01 Sep.' || E'\n'
           || '          AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from)';
    v_to   := '        WHERE  i.set_id = s.id' || E'\n'
           || '          -- MIG 852: a removal is mentioned on the record for the day the' || E'\n'
           || '          -- action was taken, and on no other. EQUALS, not greater-than.' || E'\n'
           || '          --' || E'\n'
           || '          --   removed_on = effective_from   this period BEGINS with the change.' || E'\n'
           || '          --                                 Shown, struck, with ended_on -- the' || E'\n'
           || '          --                                 last day the assignment was valid.' || E'\n'
           || '          --                                 The record of the action.' || E'\n'
           || '          --   removed_on > effective_from   the marker sits on a period the' || E'\n'
           || '          --                                 assignment ran THROUGH. A past' || E'\n'
           || '          --                                 record. Hidden -- and 852''s writer' || E'\n'
           || '          --                                 no longer creates any.' || E'\n'
           || '          --   removed_on < effective_from   retroactive (844 CASE 1), or a' || E'\n'
           || '          --                                 marker dragged forward. A future' || E'\n'
           || '          --                                 record. Hidden. This is the leak' || E'\n'
           || '          --                                 849''s first draft let through, where' || E'\n'
           || '          --                                 a removal dated 01 Jul showed on a' || E'\n'
           || '          --                                 period beginning 01 Sep.' || E'\n'
           || '          AND  (i.removed_on IS NULL OR i.removed_on = s.effective_from)';
    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 852 FAILED: expected 1 history filter, found %. '
                      'The live definition is not what 850 left.', v_hits;
    END IF;
    EXECUTE replace(v_src, v_from, v_to);
    RAISE NOTICE 'MIG 852: get_job_relationships_history patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The writer puts it where the reader looks
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 852 FAILED: fn_close_and_replace_job_relationship_set() does not exist.';
  END IF;
  IF position('MIG 851' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: 851 has not been applied -- the carry-forward anchors below expect it.';
  END IF;

  IF position('MIG 852' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 852: the writer already records on the day of the action -- skipping.';
  ELSE

    -- ── 2a. the pre-pass comes out ──
    v_from := '  -- ═══ MIG 850: a removal gets a record of its own ═══════════════════' || E'\n'
           || '  -- Before anything else, make sure a set BEGINS on the last day the' || E'\n'
           || '  -- assignment was valid. Everything below then works on the right set' || E'\n'
           || '  -- without being told: CASE 3 closes it at exactly that day and stamps' || E'\n'
           || '  -- the marker on it, which is what it always did -- to a set that could' || E'\n'
           || '  -- span months, so the whole period read as ended.' || E'\n'
           || '  --' || E'\n'
           || '  -- Only when there is something to remove. An ordinary change must not' || E'\n'
           || '  -- leave a one-day set behind it.' || E'\n'
           || '  --' || E'\n'
           || '  -- Only for CASE 2 and CASE 3. A retroactive removal (CASE 1, the active' || E'\n'
           || '  -- set starts after this date) is 844''s deliberate no-walk-forward and is' || E'\n'
           || '  -- not reopened here.' || E'\n'
           || '  IF array_length(p_remove_codes, 1) > 0' || E'\n'
           || '     AND (v_old_set.id IS NULL OR v_old_set.effective_from <= p_effective_from)' || E'\n'
           || '  THEN' || E'\n'
           || '    v_mark_id := fn_jr_open_removal_record(p_employee_id, p_effective_from - 1, p_actor);' || E'\n'
           || '' || E'\n'
           || '    -- The split may have handed the open-ended range to a new set, so the' || E'\n'
           || '    -- row read above can be stale. Read it again before dispatching.' || E'\n'
           || '    SELECT * INTO v_old_set' || E'\n'
           || '    FROM   employee_job_relationship_set' || E'\n'
           || '    WHERE  employee_id  = p_employee_id' || E'\n'
           || '      AND  is_active    = true' || E'\n'
           || '      AND  effective_to = ''9999-12-31''::date' || E'\n'
           || '    FOR UPDATE;' || E'\n'
           || '  END IF;' || E'\n';
    v_to   := '  -- MIG 852: the pre-pass is gone.' || E'\n'
           || '  --' || E'\n'
           || '  -- 850 opened a set on the LAST VALID DAY and marked the removal there, so' || E'\n'
           || '  -- history read 01 Jul - 30 Jul, then a one-day 31 Jul carrying the strike,' || E'\n'
           || '  -- then 01 Aug. Vj''s rule is narrower: mention the change on the record for' || E'\n'
           || '  -- the day the ACTION was taken -- 01 Aug -- and on no other. That period' || E'\n'
           || '  -- already exists; nothing needs splitting, and a period whose only content' || E'\n'
           || '  -- is a strike is a period nobody asked for.' || E'\n'
           || '  --' || E'\n'
           || '  -- v_mark_id stays declared and unused rather than being cut out of the' || E'\n'
           || '  -- DECLARE block: removing it would mean re-anchoring every patch below it' || E'\n'
           || '  -- for no behavioural gain.' || E'\n';
    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 852 FAILED: step 2a expected 1 match, found %.', v_hits;
    END IF;
    v_src := replace(v_src, v_from, v_to);


    -- ── 2b. CASE 2 marks in place, as 844 did ──
    v_from := '    -- MIG 850: the marker belongs on the record day, not here. This set' || E'\n'
           || '    -- BEGINS on the removal date, so an item marked here has removed_on =' || E'\n'
           || '    -- effective_from: invalid for every day of the set, hidden by 846''s' || E'\n'
           || '    -- history filter, and rightly so -- which left the removal recorded' || E'\n'
           || '    -- nowhere a reader could see it. It goes on the day before instead,' || E'\n'
           || '    -- and the code is deleted outright from this set: a set beginning' || E'\n'
           || '    -- after the assignment ended should not carry it at all.' || E'\n'
           || '    IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      IF v_mark_id IS NOT NULL AND v_mark_id <> v_old_set.id THEN' || E'\n'
           || '        UPDATE employee_job_relationship_item' || E'\n'
           || '        SET    removed_on = p_effective_from' || E'\n'
           || '        WHERE  set_id            = v_mark_id' || E'\n'
           || '          AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '          AND  removed_on        IS NULL;' || E'\n'
           || '' || E'\n'
           || '        DELETE FROM employee_job_relationship_item' || E'\n'
           || '        WHERE  set_id            = v_old_set.id' || E'\n'
           || '          AND  relationship_code = ANY(p_remove_codes);' || E'\n'
           || '      ELSE' || E'\n'
           || '        -- No set covers the day before: nothing preceded this, so there is' || E'\n'
           || '        -- no period to end. 844''s behaviour, unchanged.' || E'\n'
           || '        UPDATE employee_job_relationship_item' || E'\n'
           || '        SET    removed_on = p_effective_from' || E'\n'
           || '        WHERE  set_id            = v_old_set.id' || E'\n'
           || '          AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '          AND  removed_on        IS NULL;' || E'\n'
           || '      END IF;' || E'\n'
           || '    END IF;' || E'\n';
    v_to   := '    -- MIG 852: mark in place, which is 844''s original behaviour and turns out' || E'\n'
           || '    -- to be exactly right. This set BEGINS on the removal date, so the marked' || E'\n'
           || '    -- item carries removed_on = effective_from -- the one test history now' || E'\n'
           || '    -- applies. The record of the action lands on the record for the day of' || E'\n'
           || '    -- the action, with no help from anybody.' || E'\n'
           || '    IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      UPDATE employee_job_relationship_item' || E'\n'
           || '      SET    removed_on = p_effective_from' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL;' || E'\n'
           || '    END IF;' || E'\n';
    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 852 FAILED: step 2b expected 1 match, found %.', v_hits;
    END IF;
    v_src := replace(v_src, v_from, v_to);


    -- ── 2c. CASE 3 stops marking the period it closes ──
    v_from := '      -- Soft-delete removed slots in the closing set:' || E'\n'
           || '      -- audit trail for why the new set does not carry them forward' || E'\n'
           || '      IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '        UPDATE employee_job_relationship_item' || E'\n'
           || '        SET    removed_on = p_effective_from' || E'\n'
           || '        WHERE  set_id            = v_old_set.id' || E'\n'
           || '          AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '          AND  removed_on        IS NULL;' || E'\n'
           || '      END IF;' || E'\n';
    v_to   := '      -- MIG 852: the closing set keeps its assignments LIVE.' || E'\n'
           || '      --' || E'\n'
           || '      -- 844 marked them here, where removed_on = effective_to + 1. Under the' || E'\n'
           || '      -- equals rule that row is invisible -- and invisible is not the same as' || E'\n'
           || '      -- absent: this period is one the relationship ran through from end to' || E'\n'
           || '      -- end, so hiding the manager here says she was not the PM01 in July,' || E'\n'
           || '      -- which is false. The marker does not belong on this set at all. It is' || E'\n'
           || '      -- written into the NEW set below, where removed_on = effective_from.' || E'\n'
           || '      --' || E'\n'
           || '      -- Nothing depended on it: the carry-forward excludes the removed codes' || E'\n'
           || '      -- by name, not by the marker.' || E'\n';
    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 852 FAILED: step 2c expected 1 match, found %.', v_hits;
    END IF;
    v_src := replace(v_src, v_from, v_to);


    -- ── 2d. and writes the ended row into the period that begins that day ──
    v_from := '    -- Carry forward (skip soft-deleted items and explicitly removed codes)' || E'\n'
           || '    IF v_old_set.id IS NOT NULL THEN' || E'\n'
           || '      -- MIG 851: source_project_id travels with the slot.' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  removed_on        IS NULL' || E'\n'
           || '        AND  relationship_code <> ALL(p_remove_codes)' || E'\n'
           || '      ON CONFLICT DO NOTHING;' || E'\n'
           || '    END IF;' || E'\n';
    v_to   := '    -- Carry forward (skip soft-deleted items and explicitly removed codes)' || E'\n'
           || '    IF v_old_set.id IS NOT NULL THEN' || E'\n'
           || '      -- MIG 851: source_project_id travels with the slot.' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  removed_on        IS NULL' || E'\n'
           || '        AND  relationship_code <> ALL(p_remove_codes)' || E'\n'
           || '      ON CONFLICT DO NOTHING;' || E'\n'
           || '    END IF;' || E'\n'
           || '' || E'\n'
           || '    -- ═══ MIG 852: the record of the action, on the day it was taken ═══' || E'\n'
           || '    -- The block above deliberately leaves the removed codes out, and the' || E'\n'
           || '    -- closing set no longer carries a marker for them, so without this the' || E'\n'
           || '    -- removal would appear nowhere and the slot would simply empty.' || E'\n'
           || '    --' || E'\n'
           || '    -- The ended row is written into the NEW set, carrying removed_on = its' || E'\n'
           || '    -- own effective_from. That is the one period whose first day IS the' || E'\n'
           || '    -- action. It is inert: every reader that asks who a manager is filters' || E'\n'
           || '    -- on removed_on, carry-forward skips it, and it does not hold the slot.' || E'\n'
           || '    -- It carries source_project_id so that the row recording the end of a' || E'\n'
           || '    -- project''s assignment says which project''s (851).' || E'\n'
           || '    --' || E'\n'
           || '    -- Written BEFORE the new-items loop below on purpose: removing a code and' || E'\n'
           || '    -- re-assigning it in the same call must finish as an assignment, and that' || E'\n'
           || '    -- loop''s ON CONFLICT clears removed_on. Order decides it.' || E'\n'
           || '    IF v_old_set.id IS NOT NULL AND array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, p_effective_from, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL' || E'\n'
           || '      ON CONFLICT DO NOTHING;' || E'\n'
           || '    END IF;' || E'\n';
    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 852 FAILED: step 2d expected 1 match, found %.', v_hits;
    END IF;
    v_src := replace(v_src, v_from, v_to);
    EXECUTE v_src;
    RAISE NOTICE 'MIG 852: fn_close_and_replace_job_relationship_set patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The record-day helper has no callers left
-- ═══════════════════════════════════════════════════════════════════════════
--   Dropped rather than left lying about. A function nobody calls is a second
--   answer waiting for somebody to find it, and this thread has spent enough
--   on facts with two homes. If it is still referenced, the DROP will say so
--   rather than succeeding quietly.
DO $mig$
DECLARE v_src text;
BEGIN
  IF to_regprocedure('public.fn_jr_open_removal_record(uuid,date,uuid)') IS NULL THEN
    RAISE NOTICE 'MIG 852: fn_jr_open_removal_record already absent.';
    RETURN;
  END IF;

  SELECT string_agg(p.proname, ', ') INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    -- prokind 'f': plain functions only. pg_get_functiondef() raises on an
    -- aggregate or a window function, and pg_catalog is full of both.
    AND  p.prokind = 'f'
    AND  p.proname <> 'fn_jr_open_removal_record'
    AND  position('fn_jr_open_removal_record' IN pg_get_functiondef(p.oid)) > 0;

  IF v_src IS NOT NULL THEN
    RAISE EXCEPTION 'MIG 852 FAILED: fn_jr_open_removal_record is still called by: %', v_src;
  END IF;

  DROP FUNCTION public.fn_jr_open_removal_record(uuid, date, uuid);
  RAISE NOTICE 'MIG 852: fn_jr_open_removal_record dropped -- nothing called it.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe bigint;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'get_job_relationships_history';
  -- Matched as CODE. Every assertion in this thread that matched a phrase
  -- instead fired on the migration's own prose and cost a deploy.
  IF v_src !~ 'removed_on[[:space:]]*=[[:space:]]*s\.effective_from' THEN
    RAISE EXCEPTION 'MIG 852 FAILED: history does not test removed_on = effective_from.';
  END IF;
  IF v_src ~ 'OR[[:space:]]+i\.removed_on[[:space:]]*>[[:space:]]*s\.effective_from' THEN
    RAISE EXCEPTION 'MIG 852 FAILED: history still carries the greater-than test.';
  END IF;
  IF position('ended_on' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: history stopped returning ended_on.';
  END IF;
  IF position('user_can' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: history lost its permission gate.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'fn_close_and_replace_job_relationship_set';
  IF position('MIG 852' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: the writer did not take the replacement.';
  END IF;
  IF position('fn_jr_open_removal_record' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: the writer still calls the record-day helper.';
  END IF;
  -- 844's and 851's work must survive: 852 edits the removal path only.
  IF position('v_next_from - 1' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: the writer lost 844''s next-set bound.';
  END IF;
  IF position('v_exact.id IS NOT NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: the writer lost 844''s exact-date branch.';
  END IF;
  IF position('source_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 852 FAILED: the writer lost 851''s provenance.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the new predicate against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  (i.removed_on IS NULL OR i.removed_on = s.effective_from)
    AND  (i.removed_on - 1) IS NOT DISTINCT FROM (i.removed_on - 1);

  RAISE NOTICE 'MIG 852 OK: the mention is on the day of the action, and on no other.';
END $v$;

COMMIT;
