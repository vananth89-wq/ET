-- =============================================================================
-- Migration 850 — the record day that 849 never brought
--
-- WHAT HAPPENED
-- ═════════════
--   849 was deployed while it still contained its FIRST draft: a reader-only
--   change that dropped 846's history filter and added an `ended` array to
--   get_current_job_relationships. The file was then rewritten in place, under
--   the same name, to do something quite different -- open a record day on the
--   last valid date and mark the removal there. Supabase records a migration by
--   name and never re-runs one it has seen, so the rewrite has never reached any
--   database that took the first version. Dev is one of them. Measured there:
--
--       fn_jr_open_removal_record        absent
--       fn_close_and_replace...          no trace of 849
--       history set-start filter         REMOVED
--       history ended_on                 present
--       get_current_job_relationships    carries an `ended` key
--
--   That is the first draft exactly, and it is a state nobody asked for: with
--   the filter gone, an ended assignment is returned on every later period, so
--   the strike leaks forward -- the one thing Vj ruled out. The `ended` array is
--   read by nothing; the client that consumed it was rewritten too.
--
--   849 keeps its name and its place in the ledger. Its intended work moves
--   here, where it can be applied once, in the open. The file for 849 is left on
--   disk as it stands rather than edited a third time; this header is the record
--   of the difference between it and what ran.
--
-- WHAT THIS MIGRATION DOES
-- ════════════════════════
--   1. Puts both readers back to the bodies 846 gave them, and re-adds ended_on
--      to history. Whole-body replacements rather than reverse patches: the
--      first draft's edits are known exactly, so restoring the known-good text
--      is deterministic where un-picking it would depend on matching forty lines
--      of a block that should never have been there.
--
--      846's filter STAYS. It is what keeps a strike on the one period it
--      belongs to and out of every later one, which is half of what was asked
--      for. The filter was never wrong; the marker was in the wrong place.
--
--   2. Creates fn_jr_open_removal_record and gives the writer its pre-pass, so
--      a removal opens a set on the last day the assignment was valid and marks
--      it there. Unchanged from 849's second draft, which was tested against a
--      replica of this exact database state.
--
--   A database that somehow has the second draft already -- a fresh environment
--   built from the migration files in order -- converges on the same state:
--   every step here is either a whole-body replacement or guarded on the thing
--   it creates rather than on a marker.
--
-- Depends on: 835 (removed_on), 844 (the writer), 846 (the readers this restores)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 0. Refuse to run against a shape this migration was not measured on
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_hist text; v_cur text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_hist FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'get_job_relationships_history';
  SELECT pg_get_functiondef(p.oid) INTO v_cur  FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'get_current_job_relationships';

  IF v_hist IS NULL OR v_cur IS NULL THEN
    RAISE EXCEPTION 'MIG 850 FAILED: 846''s readers are missing -- this database is older than expected.';
  END IF;
  IF position('user_can' IN v_hist) = 0 OR position('user_can' IN v_cur) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: a reader has lost its permission gate; refusing to overwrite it.';
  END IF;
  -- Both bodies below came from 846. If something later than 850 has written
  -- them, replacing wholesale would silently undo it.
  IF v_hist ~ 'MIG 85[1-9]' OR v_cur ~ 'MIG 85[1-9]' THEN
    RAISE EXCEPTION 'MIG 850 FAILED: a later migration owns these readers -- refusing to overwrite.';
  END IF;
  RAISE NOTICE 'MIG 850: readers checked; restoring 846''s bodies.';
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The readers, back to 846 -- and history says which day it was
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_current_job_relationships(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_set    employee_job_relationship_set%ROWTYPE;
  v_items  jsonb;
BEGIN
  IF NOT user_can('job_relationships', 'view', p_employee_id)
    AND NOT user_can('job_relationships', 'view', NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- MIG 850 restored 846's body verbatim.
  -- MIG 846: the set IN FORCE TODAY, by date. It used to be chosen by the
  -- active flag together with the 9999 sentinel, which is a different question
  -- -- that returns the open-ended set, and a post-dated change makes the
  -- open-ended set one that has not started yet. ORDER BY covers the
  -- overlapping history 844's constraint now forbids but older rows may still
  -- carry: prefer the latest start.
  --
  -- (The old predicate is described rather than quoted on purpose. The
  -- verification below asserts it is gone, and a comment containing it makes
  -- that assertion fire on a migration that applied perfectly -- which is
  -- exactly how 839 and 844 each lost a deploy.)
  SELECT * INTO v_set
  FROM   employee_job_relationship_set
  WHERE  employee_id = p_employee_id
    AND  CURRENT_DATE BETWEEN effective_from AND effective_to
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'set', NULL, 'items', '[]'::jsonb);
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                   i.id,
      'relationship_code',    i.relationship_code,
      'manager_employee_id',  i.manager_employee_id,
      'manager_name',         e.name,
      'manager_employee_code', e.employee_id,
      'created_at',           i.created_at
    ) ORDER BY pv.ref_id
  ) INTO v_items
  FROM   employee_job_relationship_item i
  JOIN   employees e  ON e.id = i.manager_employee_id
  LEFT JOIN picklist_values pv
    ON pv.ref_id = i.relationship_code
   AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
  WHERE  i.set_id = v_set.id
    -- MIG 846: an assignment ended on or before today is not a current
    -- manager. One ending in the future still is, until that day.
    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE);

  RETURN jsonb_build_object(
    'ok',   true,
    'set',  jsonb_build_object(
              'id',             v_set.id,
              'effective_from', v_set.effective_from,
              'effective_to',   v_set.effective_to,
              'is_active',      v_set.is_active,
              'created_at',     v_set.created_at
            ),
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_job_relationships_history(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sets jsonb;
BEGIN
  IF NOT user_can('job_relationships', 'history', p_employee_id)
    AND NOT user_can('job_relationships', 'view',    p_employee_id)
    AND NOT user_can('job_relationships', 'history', NULL)
    AND NOT user_can('job_relationships', 'view',    NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',             s.id,
      'effective_from', s.effective_from,
      'effective_to',   s.effective_to,
      'is_active',      s.is_active,
      'created_at',     s.created_at,
      'items', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id',                  i.id,
            'relationship_code',   i.relationship_code,
            'manager_employee_id', i.manager_employee_id,
            'manager_name',        e.name,
            'manager_employee_code', e.employee_id,
            -- MIG 846: returned so the panel can print "removed 15 Aug" on an
            -- assignment that ended DURING this set, instead of dropping it and
            -- leaving the reader to wonder where it went.
            'removed_on',          i.removed_on,
            -- MIG 850: the LAST DAY the assignment was valid. removed_on is
            -- the first day it was not, which is the correct thing to store
            -- and the wrong thing to print: an assignment delimited to 31 Aug
            -- carries removed_on = 01 Sep, and "removed 01 Sep" is not what
            -- anybody typed. Computed here so no reader has to do date
            -- arithmetic to be right.
            'ended_on',            (i.removed_on - 1)
          ) ORDER BY pv.ref_id
        )
        FROM   employee_job_relationship_item i
        JOIN   employees e ON e.id = i.manager_employee_id
        LEFT JOIN picklist_values pv
          ON pv.ref_id = i.relationship_code
         AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
        WHERE  i.set_id = s.id
          -- MIG 846: compared against THIS SET's start, not against today. An
          -- item ended 01 Sep was valid for every day of a 01 Jul - 31 Aug set
          -- and belongs in it; it is not part of a set beginning 01 Sep.
          AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from)
      )
    )
    ORDER BY s.effective_from DESC
  ) INTO v_sets
  FROM employee_job_relationship_set s
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object(
    'ok',   true,
    'sets', COALESCE(v_sets, '[]'::jsonb)
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The record day
-- ═══════════════════════════════════════════════════════════════════════════
-- Created only when absent, deliberately. 851 patches this function in place
-- to carry source_project_id through the clone; an unconditional CREATE OR
-- REPLACE here would silently undo that if 850 were ever re-run after it.
-- Migration tooling runs each file once, in order -- but this whole migration
-- exists because a file ran with contents nobody expected, so the assumption
-- is not one to lean on twice.
DO $outer$
BEGIN
  IF to_regprocedure('public.fn_jr_open_removal_record(uuid,date,uuid)') IS NOT NULL THEN
    RAISE NOTICE 'MIG 850: the record-day helper already exists -- leaving it alone.';
  ELSE
    EXECUTE $create$
CREATE OR REPLACE FUNCTION public.fn_jr_open_removal_record(
  p_employee_id uuid,
  p_last_valid  date,
  p_actor       uuid DEFAULT NULL::uuid
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cover employee_job_relationship_set%ROWTYPE;
  v_after employee_job_relationship_set%ROWTYPE;
  v_id    uuid;
BEGIN
  -- The set in force on the last valid day. ORDER BY covers the overlapping
  -- history 844's constraint now forbids but older rows may still carry.
  SELECT * INTO v_cover
  FROM   employee_job_relationship_set
  WHERE  employee_id = p_employee_id
    AND  p_last_valid BETWEEN effective_from AND effective_to
  ORDER  BY effective_from DESC
  LIMIT  1
  FOR UPDATE;

  -- ── No set covers that day ──────────────────────────────────────────────
  -- Either every set starts after it -- an employee whose first job-relationship
  -- set was entered on the day the change takes effect, which is the common
  -- shape for a project assignment delimited retroactively -- or the day falls
  -- in a gap between sets. Both used to end with the marker stamped on a set
  -- that BEGINS on the removal date, where removed_on = effective_from, which
  --846's filter hides: the slot emptied and nothing anywhere said why. That is
  -- the report this migration answers, so it gets a record day too.
  --
  -- Its contents are cloned from the earliest set that starts after the day,
  -- because that set is the one the removal is about to empty and its items are
  -- the nearest recorded answer to "who held these slots". Nothing is invented
  -- that the table did not already assert.
  IF NOT FOUND THEN
    SELECT * INTO v_after
    FROM   employee_job_relationship_set
    WHERE  employee_id     = p_employee_id
      AND  effective_from  > p_last_valid
    ORDER  BY effective_from
    LIMIT  1
    FOR UPDATE;

    -- Nothing before it and nothing after it: there is no removal to record.
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    INSERT INTO employee_job_relationship_set
          (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_last_valid, p_last_valid, false, p_actor, p_actor)
    RETURNING id INTO v_id;

    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
    SELECT v_id, relationship_code, manager_employee_id
    FROM   employee_job_relationship_item
    WHERE  set_id     = v_after.id
      AND  removed_on IS NULL;

    RETURN v_id;
  END IF;

  -- Already begins there -- a second removal on the same date, or a set that
  -- happens to start on it. Nothing to split.
  IF v_cover.effective_from = p_last_valid THEN
    RETURN v_cover.id;
  END IF;

  -- Close the covering set the day before, THEN open the record day.
  -- Order is not cosmetic: ejrs_no_overlap rejects the INSERT while the old
  -- range still covers that day, and idx_ejrs_one_active rejects a second
  -- open-ended active set. Both fire before the split is visible.
  UPDATE employee_job_relationship_set
  SET    effective_to = p_last_valid - 1,
         is_active    = false,
         updated_by   = p_actor,
         updated_at   = NOW()
  WHERE  id = v_cover.id;

  -- v_cover was read before that UPDATE, so effective_to and is_active here
  -- are the ones the covering set had: the new set takes over the rest of its
  -- range unchanged, and the caller narrows it to the single day if it is
  -- closing it anyway.
  INSERT INTO employee_job_relationship_set
        (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
  VALUES (p_employee_id, p_last_valid, v_cover.effective_to, v_cover.is_active, p_actor, p_actor)
  RETURNING id INTO v_id;

  -- Live items only. A marker already on the covering set belongs to the
  -- period it ended in and must not be copied into another one.
  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
  SELECT v_id, relationship_code, manager_employee_id
  FROM   employee_job_relationship_item
  WHERE  set_id     = v_cover.id
    AND  removed_on IS NULL;

  RETURN v_id;
END;
$function$;
$create$;
    RAISE NOTICE 'MIG 850: fn_jr_open_removal_record created.';
  END IF;
END $outer$;

COMMENT ON FUNCTION public.fn_jr_open_removal_record(uuid, date, uuid) IS
  'MIG 850: guarantees a job-relationship set begins on p_last_valid, splitting '
  'the set that covers that day if needed, so a removal effective the next day '
  'has a record of its own to be stamped on. Returns that set id, or NULL when '
  'no set covers the day and none follows it.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The writer opens it before it does anything else
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
  WHERE  n.nspname = 'public' AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 850 FAILED: fn_close_and_replace_job_relationship_set() does not exist.';
  END IF;

  IF position('fn_jr_open_removal_record' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 850: fn_close_and_replace_job_relationship_set already patched -- skipping.';
  ELSE

    -- ── 2a. declare the record-day id ────────────────────────────────────────
    v_from := '  v_fwd_item  employee_job_relationship_item%ROWTYPE;        -- MIG 844';
    v_to   := '  v_fwd_item  employee_job_relationship_item%ROWTYPE;        -- MIG 844' || E'\n'
           || '  v_mark_id   uuid;                                          -- MIG 850';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 850 FAILED: expected 1 v_fwd_item declaration, found %. '
                      'The live definition is not what 844 left.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    -- ── 2b. the pre-pass, right after the active set is read ─────────────────
    v_from := '  SELECT * INTO v_old_set' || E'\n'
           || '  FROM   employee_job_relationship_set' || E'\n'
           || '  WHERE  employee_id  = p_employee_id' || E'\n'
           || '    AND  is_active    = true' || E'\n'
           || '    AND  effective_to = ''9999-12-31''::date' || E'\n'
           || '  FOR UPDATE;';

    v_to   := v_from || E'\n'
           || E'\n'
           || '  -- ═══ MIG 850: a removal gets a record of its own ═══════════════════' || E'\n'
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
           || E'\n'
           || '    -- The split may have handed the open-ended range to a new set, so the' || E'\n'
           || '    -- row read above can be stale. Read it again before dispatching.' || E'\n'
           || '    SELECT * INTO v_old_set' || E'\n'
           || '    FROM   employee_job_relationship_set' || E'\n'
           || '    WHERE  employee_id  = p_employee_id' || E'\n'
           || '      AND  is_active    = true' || E'\n'
           || '      AND  effective_to = ''9999-12-31''::date' || E'\n'
           || '    FOR UPDATE;' || E'\n'
           || '  END IF;';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 850 FAILED: expected 1 active-set read to follow, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    -- ── 2c. CASE 2 marks the record day, not the set that starts on D ────────
    v_from := '    -- Soft-delete removed slots ' || chr(8212) || ' records when the assignment ended in this set' || E'\n'
           || '    IF array_length(p_remove_codes, 1) > 0 THEN' || E'\n'
           || '      UPDATE employee_job_relationship_item' || E'\n'
           || '      SET    removed_on = p_effective_from' || E'\n'
           || '      WHERE  set_id            = v_old_set.id' || E'\n'
           || '        AND  relationship_code = ANY(p_remove_codes)' || E'\n'
           || '        AND  removed_on        IS NULL;' || E'\n'
           || '    END IF;';

    v_to   := '    -- MIG 850: the marker belongs on the record day, not here. This set' || E'\n'
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
           || E'\n'
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
           || '    END IF;';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 850 FAILED: expected 1 CASE 2 soft-delete block, found %. '
                      'CASE 1 and CASE 3 carry different comments; if this found 0 the '
                      'live text has moved and the patch must be re-anchored.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 850: fn_close_and_replace_job_relationship_set patched.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe bigint;
BEGIN
  IF to_regprocedure('public.fn_jr_open_removal_record(uuid,date,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the record-day helper was not created.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'fn_close_and_replace_job_relationship_set';
  IF position('fn_jr_open_removal_record' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the writer does not call the record-day helper.';
  END IF;
  -- 844's own work must survive: this migration edits the removal path only.
  IF position('v_next_from - 1' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the writer lost 844''s next-set bound.';
  END IF;
  IF position('v_exact.id IS NOT NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the writer lost 844''s exact-date branch.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'get_job_relationships_history';
  -- Matched as code, not as the bare phrase, so the prose above -- which
  -- describes the filter at length -- cannot fire it. Four deploys have been
  -- lost to that mistake in this thread alone.
  IF v_src !~ 'removed_on[[:space:]]*>[[:space:]]*s\.effective_from' THEN
    RAISE EXCEPTION 'MIG 850 FAILED: 846''s set-start filter was not restored.';
  END IF;
  IF position('ended_on' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: history does not return ended_on.';
  END IF;
  IF position('user_can' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: history lost its permission gate.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'get_current_job_relationships';
  -- The orphan from the first draft. Nothing reads it; leaving it would mean
  -- two answers to "who are her managers" in one payload.
  IF position('''ended''' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the abandoned ended key is still in the current reader.';
  END IF;
  IF v_src !~ 'removed_on[[:space:]]+IS[[:space:]]+NULL[[:space:]]+OR[[:space:]]+i\.removed_on[[:space:]]*>[[:space:]]*CURRENT_DATE' THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the current reader lost its today filter.';
  END IF;
  IF position('CURRENT_DATE BETWEEN effective_from AND effective_to' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the current reader does not select by date.';
  END IF;
  IF position('user_can' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 850 FAILED: the current reader lost its permission gate.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the restored queries against the real tables so every column
  -- resolves -- these are whole-body replacements, so a typo in either would
  -- otherwise surface on the first user who opened the panel.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  CURRENT_DATE BETWEEN s.effective_from AND s.effective_to
    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE)
    AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from)
    AND  (i.removed_on - 1) IS NOT DISTINCT FROM (i.removed_on - 1);

  RAISE NOTICE 'MIG 850 OK: the filter is back, the orphan is gone, and a removal opens its own record day.';
END $v$;

COMMIT;
