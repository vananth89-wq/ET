-- =============================================================================
-- Migration 849 — a removal is a record, not an absence
--
-- THE REPORT
-- ══════════
--   "If we can insert a record on the day and highlight the removal it will be
--    helpful."
--
--   JCDC: Vijaya's project assignment is delimited to 31 Aug 2026. The database
--   does the right thing and writes the removal down. The screen shows a set
--   that simply does not contain PM05, and nothing anywhere says it ended.
--
-- THE RECORD ALREADY EXISTS. IT IS THE ONE ROW WE NEVER SHOW.
-- ══════════════════════════════════════════════════════════
--   844 writes a removal in one of exactly two shapes, and never any other:
--
--     CASE 3  the active set is closed at removal_date - 1 and a new set opens
--             on removal_date. The removal marker is stamped on the CLOSING
--             set, so removed_on = closing_set.effective_to + 1, which is
--             strictly greater than that set's effective_from.
--
--     CASE 2  a set already starts on exactly removal_date. The marker is
--             stamped in place on THAT set, so removed_on = effective_from.
--
--   Carry-forward (844, CASE 3) copies items `WHERE removed_on IS NULL`, so a
--   removed row never propagates. A marker therefore lives on exactly one set,
--   and always satisfies removed_on >= that set's effective_from.
--
--   846 filtered history with `removed_on > s.effective_from`. That keeps
--   CASE 3 -- and drops CASE 2, which is the row that records the removal ON
--   THE DAY. The one event the reader came looking for was the only one never
--   shown. Vijaya's set beginning 01 Sep holds PM05 Insaf with removed_on =
--   01 Sep; the panel is told nothing about it and prints two managers where
--   yesterday there were three.
--
--   So nothing needs inserting. The row is there. This migration stops hiding
--   it and hands the panel enough to say what it is.
--
-- WHAT CHANGES
-- ════════════
--   get_job_relationships_history — returns EVERY item of every set, each with
--     removed_on and ended_on (= removed_on - 1, the last day it was valid).
--     The panel classifies:
--       removed_on IS NULL                 live for the whole period
--       removed_on >  s.effective_from     ended DURING this period
--       removed_on <= s.effective_from     ended AS this period began
--     The filter moves from the database to the reader because only the reader
--     can render the difference; a filter can only delete it.
--
--   get_current_job_relationships — gains `ended`, a separate array of the
--     in-force set's items whose removal has already taken effect. `items` is
--     untouched: it still means "who her managers are today", and no caller
--     that reads it can be surprised by this migration.
--
-- WHY NOT JUST LOOSEN THE FILTER TO `>=`
-- ══════════════════════════════════════
--   Because `>=` still hands the client a row it cannot tell from a live one,
--   and 846 recorded what that costs: the Edit form builds its slots from
--   whatever history returns, so a removed row that arrives looking live is
--   re-submitted as live and the assignment comes back from the dead. The
--   client change that ships with this migration excludes removed rows from
--   the edit slots, from the assigned-count and from the empty-state test.
--   Returning the marker is only safe together with that.
--
-- Depends on: 835 (removed_on), 844 (the two shapes), 846 (these two readers)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. get_job_relationships_history — every item, and what became of it
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_from text;
  v_to   text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_job_relationships_history';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 849 FAILED: get_job_relationships_history() does not exist.';
  END IF;

  IF position('MIG 849' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 849: get_job_relationships_history already patched -- skipping.';
  ELSE

    -- ── 1a. drop the set-start filter ────────────────────────────────────────
    v_from := '        WHERE  i.set_id = s.id' || E'\n'
           || '          -- MIG 846: compared against THIS SET''s start, not against today. An' || E'\n'
           || '          -- item ended 01 Sep was valid for every day of a 01 Jul - 31 Aug set' || E'\n'
           || '          -- and belongs in it; it is not part of a set beginning 01 Sep.' || E'\n'
           || '          AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from)';

    v_to   := '        WHERE  i.set_id = s.id' || E'\n'
           || '          -- MIG 849: no filter, on purpose. 846''s test kept an item that ended' || E'\n'
           || '          -- DURING a set and dropped one that ended AS the set began -- and the' || E'\n'
           || '          -- second is exactly the row that records a removal on the day it took' || E'\n'
           || '          -- effect. Both are returned, each carrying removed_on and ended_on, and' || E'\n'
           || '          -- the panel decides how to draw them. A reader can show the difference;' || E'\n'
           || '          -- a filter can only delete it.';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: expected 1 history filter to remove, found %. '
                      'The live definition is not what 846 left.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    -- ── 1b. ended_on beside removed_on ───────────────────────────────────────
    v_from := '            ''removed_on'',          i.removed_on';
    v_to   := '            ''removed_on'',          i.removed_on,' || E'\n'
           || '            -- MIG 849: the LAST DAY the assignment was valid. removed_on is the' || E'\n'
           || '            -- first day it was not, which is the correct thing to store and the' || E'\n'
           || '            -- wrong thing to print: an assignment delimited to 31 Aug carries' || E'\n'
           || '            -- removed_on = 01 Sep, and "removed 01 Sep" is not what was typed.' || E'\n'
           || '            -- Computed here so no reader has to do date arithmetic to be right.' || E'\n'
           || '            ''ended_on'',            (i.removed_on - 1)';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: expected 1 removed_on key in history, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 849: get_job_relationships_history patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. get_current_job_relationships — and what has already ended
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_from text;
  v_to   text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_current_job_relationships';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 849 FAILED: get_current_job_relationships() does not exist.';
  END IF;

  IF position('MIG 849' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 849: get_current_job_relationships already patched -- skipping.';
  ELSE

    -- ── 2a. declare v_ended ──────────────────────────────────────────────────
    v_from := '  v_items  jsonb;';
    v_to   := '  v_items  jsonb;' || E'\n'
           || '  v_ended  jsonb;   -- MIG 849';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: expected 1 v_items declaration, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    -- ── 2b. collect the slots whose removal has already taken effect ─────────
    --
    -- Anchored on the end of the items query plus the RETURN that follows it,
    -- so the new block cannot land anywhere else in the body.
    v_from := '    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE);' || E'\n'
           || E'\n'
           || '  RETURN jsonb_build_object(';

    v_to   := '    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE);' || E'\n'
           || E'\n'
           || '  -- MIG 849: the other half of the same picture -- the slots whose removal has' || E'\n'
           || '  -- ALREADY taken effect. Kept in its own key rather than mixed into items,' || E'\n'
           || '  -- because items means "her managers today" and every caller reads it that' || E'\n'
           || '  -- way; a migration about showing a removal must not change what "current"' || E'\n'
           || '  -- means. One ending in the FUTURE is deliberately not here: it is still a' || E'\n'
           || '  -- live assignment and is still in items, until the day.' || E'\n'
           || '  --' || E'\n'
           || '  -- Selected by DATE, not by set, and that is the whole point. 844 writes the' || E'\n'
           || '  -- marker on the CLOSING set when it has to split (the usual case), and on' || E'\n'
           || '  -- the in-force set itself when one already starts on the removal date. Keyed' || E'\n'
           || '  -- to v_set.id this would show the second and miss the first, so the screen' || E'\n'
           || '  -- would report a removal or not depending on whether a set boundary happened' || E'\n'
           || '  -- to exist -- which is not a distinction any user can see or predict.' || E'\n'
           || '  -- removed_on >= v_set.effective_from covers both, because both mean the same' || E'\n'
           || '  -- thing: this is a removal that shaped the set now in force. Anything older' || E'\n'
           || '  -- belongs to a period this screen is not showing; History has it.' || E'\n'
           || '  SELECT jsonb_agg(' || E'\n'
           || '    jsonb_build_object(' || E'\n'
           || '      ''id'',                   d.id,' || E'\n'
           || '      ''relationship_code'',    d.relationship_code,' || E'\n'
           || '      ''manager_employee_id'',  d.manager_employee_id,' || E'\n'
           || '      ''manager_name'',         d.manager_name,' || E'\n'
           || '      ''manager_employee_code'', d.manager_employee_code,' || E'\n'
           || '      ''removed_on'',           d.removed_on,' || E'\n'
           || '      ''ended_on'',             (d.removed_on - 1)' || E'\n'
           || '    ) ORDER BY d.ref_id' || E'\n'
           || '  ) INTO v_ended' || E'\n'
           || '  FROM (' || E'\n'
           || '    -- One row per slot. A slot removed, re-assigned and removed again inside' || E'\n'
           || '    -- the same window carries two markers; the latest is the true one.' || E'\n'
           || '    SELECT DISTINCT ON (i.relationship_code)' || E'\n'
           || '           i.id, i.relationship_code, i.manager_employee_id, i.removed_on,' || E'\n'
           || '           e.name AS manager_name, e.employee_id AS manager_employee_code,' || E'\n'
           || '           pv.ref_id' || E'\n'
           || '    FROM   employee_job_relationship_set  s' || E'\n'
           || '    JOIN   employee_job_relationship_item i ON i.set_id = s.id' || E'\n'
           || '    JOIN   employees e  ON e.id = i.manager_employee_id' || E'\n'
           || '    LEFT JOIN picklist_values pv' || E'\n'
           || '      ON pv.ref_id = i.relationship_code' || E'\n'
           || '     AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = ''JOB_RELATIONSHIP_TYPE'')' || E'\n'
           || '    WHERE  s.employee_id  = p_employee_id' || E'\n'
           || '      AND  i.removed_on IS NOT NULL' || E'\n'
           || '      AND  i.removed_on <= CURRENT_DATE' || E'\n'
           || '      AND  i.removed_on >= v_set.effective_from' || E'\n'
           || '    ORDER  BY i.relationship_code, i.removed_on DESC' || E'\n'
           || '  ) d' || E'\n'
           || '  -- and not one that has since been filled again: that is not a vacancy.' || E'\n'
           || '  WHERE NOT EXISTS (' || E'\n'
           || '    SELECT 1 FROM employee_job_relationship_item li' || E'\n'
           || '    WHERE  li.set_id            = v_set.id' || E'\n'
           || '      AND  li.relationship_code = d.relationship_code' || E'\n'
           || '      AND  (li.removed_on IS NULL OR li.removed_on > CURRENT_DATE)' || E'\n'
           || '  );' || E'\n'
           || E'\n'
           || '  RETURN jsonb_build_object(';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: expected 1 items-then-RETURN anchor, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    -- ── 2c. return it ────────────────────────────────────────────────────────
    v_from := '    ''items'', COALESCE(v_items, ''[]''::jsonb)';
    v_to   := '    ''items'', COALESCE(v_items, ''[]''::jsonb),' || E'\n'
           || '    ''ended'', COALESCE(v_ended, ''[]''::jsonb)';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: expected 1 items key in the payload, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 849: get_current_job_relationships patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE
  v_src   text;
  v_fn    text;
  v_probe bigint;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['get_current_job_relationships',
                              'get_job_relationships_history']
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'MIG 849 FAILED: %() is missing.', v_fn;
    END IF;
    IF position('MIG 849' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: %() did not take the replacement.', v_fn;
    END IF;
    IF position('ended_on' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: %() does not return ended_on.', v_fn;
    END IF;
    -- 846's note, still true: a migration about display that quietly widens
    -- access is worse than the bug it fixes.
    IF position('user_can' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 849 FAILED: %() lost its permission gate.', v_fn;
    END IF;
  END LOOP;

  -- The set-start filter must be gone from history, and ONLY from history.
  -- Matched as code, not as the bare phrase, so the prose above -- which
  -- quotes the old predicate on purpose -- cannot fire this. That mistake
  -- has cost three deploys (839, 844, 846); it does not get a fourth.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_job_relationships_history';
  IF v_src ~ 'removed_on[[:space:]]*>[[:space:]]*s\.effective_from' THEN
    RAISE EXCEPTION 'MIG 849 FAILED: history still filters items by the set start.';
  END IF;

  -- And the today-filter must SURVIVE on the current reader: `items` still
  -- means today. Losing it would put ended managers back on the live screen.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_current_job_relationships';
  IF v_src !~ 'removed_on[[:space:]]+IS[[:space:]]+NULL[[:space:]]+OR[[:space:]]+i\.removed_on[[:space:]]*>[[:space:]]*CURRENT_DATE' THEN
    RAISE EXCEPTION 'MIG 849 FAILED: get_current_job_relationships lost its today filter.';
  END IF;
  IF position('''ended''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 849 FAILED: get_current_job_relationships does not return an ended key.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the new query against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM (
    SELECT DISTINCT ON (i.relationship_code)
           i.id, i.relationship_code, i.removed_on, e.name, pv.ref_id
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    JOIN   employees e ON e.id = i.manager_employee_id
    LEFT JOIN picklist_values pv
      ON pv.ref_id = i.relationship_code
     AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
    WHERE  i.removed_on IS NOT NULL
      AND  i.removed_on <= CURRENT_DATE
    ORDER  BY i.relationship_code, i.removed_on DESC
  ) d
  WHERE (d.removed_on - 1) <= CURRENT_DATE;

  RAISE NOTICE 'MIG 849 OK: the removal is returned, dated, and separate from what is live.';
END $v$;

COMMIT;
