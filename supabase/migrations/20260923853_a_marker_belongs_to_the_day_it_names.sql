-- =============================================================================
-- Migration 853 — a marker belongs to the day it names
--
-- WHAT WAS FOUND
-- ══════════════
--   852 made one rule: a removal is shown on the period that BEGINS on the day
--   the action was taken -- `removed_on = effective_from` -- and nowhere else.
--   A scan of Dev for markers that fail that test returned two rows, of two
--   different kinds:
--
--     Harikrishnan A   set 01 Aug - 21 Sep, PM02 Insaf, removed_on = 22 Sep
--        removed_on = effective_to + 1. The shape 844 wrote before 852: the
--        marker stamped on the set being CLOSED. He held PM02 every day of
--        that period, and 852 now hides the row -- so the period shows no PM02
--        at all. 852 stopped the writer creating these; it cannot move one
--        already written.
--
--     Vijaya B P      set 01 Oct - 9999, PM01 Iqraa, removed_on = 01 Aug
--        removed_on < effective_from. A marker carried into a period that
--        begins two months AFTER the removal it records. It means nothing
--        where it sits, and the period that should carry the mention -- the
--        one beginning 01 Aug -- holds nothing.
--
--   Neither is a defect in 852's writer. Both are rows written before it.
--
-- THE REPAIR NEEDS NO GUESSWORK
-- ═════════════════════════════
--   Each marker names its own destination: the period whose effective_from
--   equals removed_on. What differs is what to do with the row left behind,
--   and the two cases are told apart by arithmetic, not by judgement:
--
--     removed_on = effective_to + 1   the assignment ran through this period
--                                     from end to end. Clear removed_on: the
--                                     row should read LIVE, because it was.
--
--     removed_on < effective_from     the row never belonged to this period at
--                                     all. Delete it.
--
--     anything else                   a marker strictly inside a period, or
--                                     past its end by more than a day. Neither
--                                     shape this codebase produces. LEFT ALONE
--                                     and named in a NOTICE -- inventing a
--                                     reading for a row nobody can explain is
--                                     how this thread started.
--
--   Then, where a period begins on removed_on and has no row for that slot,
--   the ended row is written there: same manager, same date, same
--   source_project_id (851), so the record says whose assignment ended.
--
-- AND THE WAY THEY GOT THERE
-- ══════════════════════════
--   Two writers rebuild a set and put the old markers back afterwards:
--   admin_update_job_relationship_set (846) and the `correction` branch of
--   fn_apply_job_relationship_set_transition (847). Both carry removed_on over
--   verbatim, with nothing checking the date falls on the target's start. Put
--   a 01 Aug marker into a set beginning 01 Oct and you get Vijaya's row.
--
--   Both now keep a marker only when it matches. One that does not is not
--   restored -- neither as an ended row nor as a live one, because it was
--   never a valid statement about that period.
--
-- NOT IN THIS MIGRATION, deliberately:
--   admin_update_job_relationship_set deletes every item and rebuilds from a
--   payload that has never heard of source_project_id, so an HR Edit silently
--   turns a project-derived slot into a hand-set one and the lead-change sync
--   stops managing it. Same family, different defect, and this migration was
--   agreed as repair-and-guard. It wants its own.
--
-- Depends on: 846 and 847 (the two restore paths), 851 (provenance), 852 (the rule)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Move the strays to the day they name
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE
  r            record;
  v_target     uuid;
  v_moved      int := 0;
  v_cleared    int := 0;
  v_deleted    int := 0;
  v_unmoorable int := 0;
  v_skipped    int := 0;
BEGIN
  -- Captured up front: the loop rewrites the rows it is reading.
  CREATE TEMP TABLE _mig853_strays ON COMMIT DROP AS
  SELECT i.id            AS item_id,
         s.id            AS set_id,
         s.employee_id,
         s.effective_from,
         s.effective_to,
         i.relationship_code,
         i.manager_employee_id,
         i.removed_on,
         i.source_project_id
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  i.removed_on IS NOT NULL
    AND  i.removed_on <> s.effective_from;

  FOR r IN SELECT * FROM _mig853_strays ORDER BY employee_id, effective_from
  LOOP
    -- Neither known shape: say so and change nothing.
    IF NOT (r.removed_on = r.effective_to + 1 OR r.removed_on < r.effective_from) THEN
      RAISE NOTICE 'MIG 853: LEFT ALONE -- employee %, set % .. %, % ends %. '
                   'Not a closing-set marker and not one carried forward; '
                   'no rule here covers it.',
                   r.employee_id, r.effective_from, r.effective_to,
                   r.relationship_code, r.removed_on;
      v_unmoorable := v_unmoorable + 1;
      CONTINUE;
    END IF;

    -- The period that begins on the day this marker names.
    SELECT id INTO v_target
    FROM   employee_job_relationship_set
    WHERE  employee_id    = r.employee_id
      AND  effective_from = r.removed_on
    LIMIT  1;

    IF v_target IS NOT NULL THEN
      -- Only when that period holds nothing for the slot. If it holds a live
      -- row the slot was filled again and the ending is already told by the
      -- boundary; if it holds an ended row the record is already there.
      IF NOT EXISTS (
        SELECT 1 FROM employee_job_relationship_item
        WHERE  set_id = v_target AND relationship_code = r.relationship_code
      ) THEN
        INSERT INTO employee_job_relationship_item
              (set_id, relationship_code, manager_employee_id, removed_on, source_project_id)
        VALUES (v_target, r.relationship_code, r.manager_employee_id, r.removed_on, r.source_project_id);
        v_moved := v_moved + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    ELSE
      -- No period begins that day. Nothing to move it to; the stray is still
      -- cleared below, because leaving it says something false either way.
      RAISE NOTICE 'MIG 853: employee % has no period beginning % -- % has '
                   'nowhere to be recorded. The stray is still cleared.',
                   r.employee_id, r.removed_on, r.relationship_code;
    END IF;

    IF r.removed_on = r.effective_to + 1 THEN
      -- Ran through this period. It should read live, because it was.
      UPDATE employee_job_relationship_item
      SET    removed_on = NULL
      WHERE  id = r.item_id;
      v_cleared := v_cleared + 1;
    ELSE
      -- Never belonged to this period.
      DELETE FROM employee_job_relationship_item
      WHERE  id = r.item_id;
      v_deleted := v_deleted + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'MIG 853: % recorded on the day they name, % cleared to live, '
               '% deleted, % already recorded, % left alone.',
               v_moved, v_cleared, v_deleted, v_skipped, v_unmoorable;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. admin_update_job_relationship_set keeps only markers that match
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_new text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'admin_update_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 853 FAILED: admin_update_job_relationship_set() does not exist.';
  END IF;

  IF position('MIG 853' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 853: admin_update already guarded -- skipping.';
  ELSE
    v_from := '  UPDATE employee_job_relationship_item i' || E'\n'
           || '  SET    removed_on = p.removed_on' || E'\n'
           || '  FROM   _mig846_prior p' || E'\n'
           || '  WHERE  i.set_id              = p_set_id' || E'\n'
           || '    AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '    AND  i.manager_employee_id = p.manager_employee_id;';
    v_to   := '  -- MIG 853: and only when the marker belongs to THIS period. 846 carried' || E'\n'
           || '  -- removed_on over verbatim, so an Edit could stamp a set with a date that' || E'\n'
           || '  -- has nothing to do with it -- which 852''s rule then hides, leaving the' || E'\n'
           || '  -- removal recorded nowhere. A marker that does not match the period''s' || E'\n'
           || '  -- start is not a statement about that period, so it is not restored.' || E'\n'
           || '  UPDATE employee_job_relationship_item i' || E'\n'
           || '  SET    removed_on = p.removed_on' || E'\n'
           || '  FROM   _mig846_prior p' || E'\n'
           || '  WHERE  i.set_id              = p_set_id' || E'\n'
           || '    AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '    AND  i.manager_employee_id = p.manager_employee_id' || E'\n'
           || '    AND  p.removed_on = (SELECT effective_from' || E'\n'
           || '                         FROM   employee_job_relationship_set' || E'\n'
           || '                         WHERE  id = p_set_id);';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 853 FAILED: expected 1 admin_update marker restore, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    v_from := '  SELECT p_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '  FROM   _mig846_prior p' || E'\n'
           || '  WHERE  NOT EXISTS (' || E'\n'
           || '    SELECT 1 FROM employee_job_relationship_item i' || E'\n'
           || '    WHERE  i.set_id = p_set_id AND i.relationship_code = p.relationship_code);';
    v_to   := '  SELECT p_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '  FROM   _mig846_prior p' || E'\n'
           || '  WHERE  NOT EXISTS (' || E'\n'
           || '    SELECT 1 FROM employee_job_relationship_item i' || E'\n'
           || '    WHERE  i.set_id = p_set_id AND i.relationship_code = p.relationship_code)' || E'\n'
           || '    -- MIG 853: same test. A row whose date does not name this period comes' || E'\n'
           || '    -- back neither ended nor live: it was never true of this period.' || E'\n'
           || '    AND  p.removed_on = (SELECT effective_from' || E'\n'
           || '                         FROM   employee_job_relationship_set' || E'\n'
           || '                         WHERE  id = p_set_id);';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 853 FAILED: expected 1 admin_update marker re-insert, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 853: admin_update_job_relationship_set guarded.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. and so does the approved path's correction branch
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_new text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_apply_job_relationship_set_transition';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 853 FAILED: fn_apply_job_relationship_set_transition() does not exist.';
  END IF;

  IF position('MIG 853' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 853: the correction branch already guarded -- skipping.';
  ELSE
    v_from := '    UPDATE employee_job_relationship_item i' || E'\n'
           || '    SET    removed_on = p.removed_on' || E'\n'
           || '    FROM   _mig847_prior p' || E'\n'
           || '    WHERE  i.set_id              = v_new_set_id' || E'\n'
           || '      AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '      AND  i.manager_employee_id = p.manager_employee_id;';
    v_to   := '    -- MIG 853: only a marker that names THIS period. This branch writes into' || E'\n'
           || '    -- a set that may begin on a different date from the one the marker came' || E'\n'
           || '    -- from, which is how a removal dated 01 Aug ended up recorded on a period' || E'\n'
           || '    -- beginning 01 Oct.' || E'\n'
           || '    UPDATE employee_job_relationship_item i' || E'\n'
           || '    SET    removed_on = p.removed_on' || E'\n'
           || '    FROM   _mig847_prior p' || E'\n'
           || '    WHERE  i.set_id              = v_new_set_id' || E'\n'
           || '      AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '      AND  i.manager_employee_id = p.manager_employee_id' || E'\n'
           || '      AND  p.removed_on = (SELECT effective_from' || E'\n'
           || '                           FROM   employee_job_relationship_set' || E'\n'
           || '                           WHERE  id = v_new_set_id);';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 853 FAILED: expected 1 correction marker restore, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    v_from := '    SELECT v_new_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '    FROM   _mig847_prior p' || E'\n'
           || '    WHERE  NOT EXISTS (' || E'\n'
           || '      SELECT 1 FROM employee_job_relationship_item i' || E'\n'
           || '      WHERE  i.set_id = v_new_set_id AND i.relationship_code = p.relationship_code);';
    v_to   := '    SELECT v_new_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '    FROM   _mig847_prior p' || E'\n'
           || '    WHERE  NOT EXISTS (' || E'\n'
           || '      SELECT 1 FROM employee_job_relationship_item i' || E'\n'
           || '      WHERE  i.set_id = v_new_set_id AND i.relationship_code = p.relationship_code)' || E'\n'
           || '      -- MIG 853: same test.' || E'\n'
           || '      AND  p.removed_on = (SELECT effective_from' || E'\n'
           || '                           FROM   employee_job_relationship_set' || E'\n'
           || '                           WHERE  id = v_new_set_id);';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 853 FAILED: expected 1 correction marker re-insert, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 853: fn_apply_job_relationship_set_transition guarded.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_left bigint; v_bad bigint;
BEGIN
  -- Nothing of either known shape may survive.
  SELECT count(*) INTO v_bad
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  i.removed_on IS NOT NULL
    AND  i.removed_on <> s.effective_from
    AND  (i.removed_on = s.effective_to + 1 OR i.removed_on < s.effective_from);
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 853 FAILED: % repairable strays remain.', v_bad;
  END IF;

  -- Anything left is the third bucket, reported above and left alone on
  -- purpose. Counted, not hidden.
  SELECT count(*) INTO v_left
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  i.removed_on IS NOT NULL AND i.removed_on <> s.effective_from;
  IF v_left > 0 THEN
    RAISE WARNING 'MIG 853: % marker(s) of an unrecognised shape left untouched -- see the NOTICEs above.', v_left;
  END IF;

  FOREACH v_src IN ARRAY ARRAY['admin_update_job_relationship_set',
                               'fn_apply_job_relationship_set_transition']
  LOOP
    DECLARE v_body text;
    BEGIN
      SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE  n.nspname = 'public' AND p.proname = v_src;

      IF v_body IS NULL THEN
        RAISE EXCEPTION 'MIG 853 FAILED: %() is missing.', v_src;
      END IF;
      IF position('MIG 853' IN v_body) = 0 THEN
        RAISE EXCEPTION 'MIG 853 FAILED: %() did not take the guard.', v_src;
      END IF;
      -- Both guards, matched as code. An assertion on a phrase would fire on
      -- the prose above; that mistake has cost four deploys in this thread.
      IF (SELECT count(*) FROM regexp_matches(v_body,
            'p\.removed_on = \(SELECT effective_from', 'g')) <> 2 THEN
        RAISE EXCEPTION 'MIG 853 FAILED: %() does not carry both guards.', v_src;
      END IF;
      IF position('user_can' IN v_body) = 0 AND v_src = 'admin_update_job_relationship_set' THEN
        RAISE EXCEPTION 'MIG 853 FAILED: %() lost its permission gate.', v_src;
      END IF;
    END;
  END LOOP;

  RAISE NOTICE 'MIG 853 OK: every marker names the period it sits on, and both restore paths keep it that way.';
END $v$;

COMMIT;
