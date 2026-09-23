-- =============================================================================
-- Migration 855 — provenance survives an Edit
--
-- THE DEFECT
-- ══════════
--   851 gave a slot a memory of which project filled it, and 851's lead-change
--   sync moves only slots it owns -- NULL means a human put it there and
--   automation keeps its hands off. That promise is what makes the whole thing
--   safe. It is also what makes losing the column dangerous rather than merely
--   untidy: a slot whose source is erased does not error, it goes quiet.
--
--   Both rebuild paths erase it. admin_update_job_relationship_set deletes
--   every item in the period and re-inserts from the Edit form's payload:
--
--       INSERT INTO employee_job_relationship_item
--              (set_id, relationship_code, manager_employee_id)
--       SELECT p_set_id, elem->>'relationship_code', ...
--
--   Three columns. The payload comes from a form written months before 851 and
--   has never heard of source_project_id, so every rebuilt row defaults to
--   NULL. Measured:
--
--       1. after the project assignment
--            PM01 Suchitra N   source = QCC
--       2. HR opens History, hits Edit, saves WITHOUT CHANGING ANYTHING
--            PM01 Suchitra N   source = (none -- hand-set)
--       3. QCC's lead changes to Iqraa
--            01 Jun - Present  PM01 Suchitra N   source = (none -- hand-set)
--
--   Step 3 is the damage. The slot does not move, Iqraa never appears, and the
--   sync is doing exactly what it was told. Nothing errors and nothing looks
--   wrong on screen at the time; the loss surfaces weeks later as "the lead
--   change skipped that employee", with no reason anyone would connect it to
--   an Edit.
--
--   847's `correction` branch rebuilds the same way and loses it the same way.
--
-- THE FIX, AND WHY IT COPIES 846's OWN TEST
-- ═════════════════════════════════════════
--   Both paths already keep a temp table of what the period held before the
--   delete, so removal markers can be put back. It gains source_project_id and
--   one statement restores it -- ONLY where the manager in that slot is
--   unchanged.
--
--   That is the same condition 846 uses for markers, for the same reason. If
--   the Edit put somebody ELSE in the slot, it is a new assignment; the old
--   occupant's project says nothing about it, and inheriting the provenance
--   would hand a slot HR had just set by hand back to automation to move.
--
--   Widening the temp table to all rows, not only ended ones, is safe because
--   both marker statements compare `p.removed_on = <period start>`, and NULL
--   never equals anything -- so a live row cannot be resurrected by them. That
--   is 853's guard doing a second job.
--
-- WHAT THIS DOES NOT FIX
-- ══════════════════════
--   Slots already stripped by an Edit before this migration. They read as
--   hand-set and stay that way: which project once owned a slot is not
--   recoverable from a row that no longer says so, and guessing from current
--   project membership would re-take slots HR set deliberately -- the exact
--   guess 851 exists to avoid. Re-create the membership to re-stamp one.
--
-- Depends on: 846 and 847 (the two rebuild paths), 851 (the column), 853 (the
--             marker guard these statements sit beside)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The HR Edit path
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_new text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'admin_update_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 855 FAILED: admin_update_job_relationship_set() does not exist.';
  END IF;
  IF position('MIG 853' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 855 FAILED: 853 has not been applied -- its guard is what makes '
                    'widening the temp table safe, and these anchors expect it.';
  END IF;

  IF position('MIG 855' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 855: admin_update already keeps provenance -- skipping.';
  ELSE

    -- ── 1a. the temp table remembers every row, and where it came from ──────
    v_from := '  -- MIG 846: remember what had already ended, before the rebuild throws it away.' || E'\n'
           || '  CREATE TEMP TABLE _mig846_prior ON COMMIT DROP AS' || E'\n'
           || '  SELECT relationship_code, manager_employee_id, removed_on' || E'\n'
           || '  FROM   employee_job_relationship_item' || E'\n'
           || '  WHERE  set_id = p_set_id AND removed_on IS NOT NULL;';

    v_to   := '  -- MIG 846: remember what had already ended, before the rebuild throws it away.' || E'\n'
           || '  -- MIG 855: and which project filled each slot, for the same reason -- the' || E'\n'
           || '  -- rebuild below writes three columns and the Edit form has never heard of' || E'\n'
           || '  -- the fourth. Every row now, not only the ended ones: a LIVE row is the' || E'\n'
           || '  -- one whose provenance an Edit was silently erasing.' || E'\n'
           || '  --' || E'\n'
           || '  -- Widening this is safe because both marker statements below test' || E'\n'
           || '  -- `p.removed_on = <period start>`, and NULL equals nothing -- so a live' || E'\n'
           || '  -- row cannot be brought back by them as an ended one.' || E'\n'
           || '  CREATE TEMP TABLE _mig846_prior ON COMMIT DROP AS' || E'\n'
           || '  SELECT relationship_code, manager_employee_id, removed_on, source_project_id' || E'\n'
           || '  FROM   employee_job_relationship_item' || E'\n'
           || '  WHERE  set_id = p_set_id;';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 _mig846_prior definition, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    -- ── 1b. an ended row comes back with its project ────────────────────────
    v_from := '  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on)' || E'\n'
           || '  SELECT p_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '  FROM   _mig846_prior p';
    v_to   := '  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on, source_project_id)' || E'\n'
           || '  SELECT p_set_id, p.relationship_code, p.manager_employee_id, p.removed_on, p.source_project_id' || E'\n'
           || '  FROM   _mig846_prior p';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 ended-row restore in admin_update, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    -- ── 1c. and a live row keeps its own ────────────────────────────────────
    -- Anchored on the statement that follows, so the restore lands after the
    -- rebuild and after the markers, with nothing between it and the mirror.
    v_from := '  IF v_is_active THEN';
    v_to   := '  -- MIG 855: and a slot that is still held by the same person keeps the' || E'\n'
           || '  -- project that filled it.' || E'\n'
           || '  --' || E'\n'
           || '  -- ONLY where the manager is unchanged -- 846''s test for markers, for the' || E'\n'
           || '  -- same reason. If this Edit put somebody ELSE in the slot it is a new' || E'\n'
           || '  -- assignment, the old occupant''s project says nothing about it, and' || E'\n'
           || '  -- inheriting the provenance would hand a slot HR had just set by hand' || E'\n'
           || '  -- back to automation to move on the next lead change.' || E'\n'
           || '  UPDATE employee_job_relationship_item i' || E'\n'
           || '  SET    source_project_id = p.source_project_id' || E'\n'
           || '  FROM   _mig846_prior p' || E'\n'
           || '  WHERE  i.set_id              = p_set_id' || E'\n'
           || '    AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '    AND  i.manager_employee_id = p.manager_employee_id' || E'\n'
           || '    AND  p.source_project_id IS NOT NULL;' || E'\n'
           || E'\n'
           || '  IF v_is_active THEN';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 v_is_active branch in admin_update, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 855: admin_update_job_relationship_set keeps provenance.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The approved-correction path
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE v_src text; v_new text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_apply_job_relationship_set_transition';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 855 FAILED: fn_apply_job_relationship_set_transition() does not exist.';
  END IF;
  IF position('MIG 853' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 855 FAILED: 853 has not been applied to the correction branch.';
  END IF;

  IF position('MIG 855' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 855: the correction branch already keeps provenance -- skipping.';
  ELSE

    v_from := '    CREATE TEMP TABLE _mig847_prior ON COMMIT DROP AS' || E'\n'
           || '    SELECT relationship_code, manager_employee_id, removed_on' || E'\n'
           || '    FROM   employee_job_relationship_item' || E'\n'
           || '    WHERE  set_id = v_target_id AND removed_on IS NOT NULL;';
    v_to   := '    -- MIG 855: every row, and where it came from. Same defect as the HR' || E'\n'
           || '    -- Edit path: this branch rebuilds the period from a payload that has' || E'\n'
           || '    -- never heard of source_project_id, so an approved correction was' || E'\n'
           || '    -- silently taking project-derived slots out of 851''s reach.' || E'\n'
           || '    CREATE TEMP TABLE _mig847_prior ON COMMIT DROP AS' || E'\n'
           || '    SELECT relationship_code, manager_employee_id, removed_on, source_project_id' || E'\n'
           || '    FROM   employee_job_relationship_item' || E'\n'
           || '    WHERE  set_id = v_target_id;';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 _mig847_prior definition, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    v_from := '    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on)' || E'\n'
           || '    SELECT v_new_set_id, p.relationship_code, p.manager_employee_id, p.removed_on' || E'\n'
           || '    FROM   _mig847_prior p';
    v_to   := '    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on, source_project_id)' || E'\n'
           || '    SELECT v_new_set_id, p.relationship_code, p.manager_employee_id, p.removed_on, p.source_project_id' || E'\n'
           || '    FROM   _mig847_prior p';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 ended-row restore in the correction branch, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    -- The live-row restore goes immediately before the temp table is dropped,
    -- which is the last thing the branch does with it.
    v_from := '    DROP TABLE IF EXISTS _mig847_prior;';
    v_to   := '    -- MIG 855: a slot still held by the same person keeps its project.' || E'\n'
           || '    -- Manager unchanged only, for the reason 846 gives about markers: a' || E'\n'
           || '    -- different occupant is a new assignment and must not inherit it.' || E'\n'
           || '    UPDATE employee_job_relationship_item i' || E'\n'
           || '    SET    source_project_id = p.source_project_id' || E'\n'
           || '    FROM   _mig847_prior p' || E'\n'
           || '    WHERE  i.set_id              = v_new_set_id' || E'\n'
           || '      AND  i.relationship_code   = p.relationship_code' || E'\n'
           || '      AND  i.manager_employee_id = p.manager_employee_id' || E'\n'
           || '      AND  p.source_project_id IS NOT NULL;' || E'\n'
           || E'\n'
           || '    DROP TABLE IF EXISTS _mig847_prior;';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 855 FAILED: expected 1 _mig847_prior drop, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 855: fn_apply_job_relationship_set_transition keeps provenance.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY['admin_update_job_relationship_set',
                                'fn_apply_job_relationship_set_transition']
  LOOP
    DECLARE v_body text;
    BEGIN
      SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE  n.nspname = 'public' AND p.proname = v_name;

      IF v_body IS NULL THEN
        RAISE EXCEPTION 'MIG 855 FAILED: %() is missing.', v_name;
      END IF;
      IF position('MIG 855' IN v_body) = 0 THEN
        RAISE EXCEPTION 'MIG 855 FAILED: %() did not take the change.', v_name;
      END IF;
      -- The restore, matched as code rather than as a phrase.
      IF v_body !~ 'SET    source_project_id = p\.source_project_id' THEN
        RAISE EXCEPTION 'MIG 855 FAILED: %() does not restore provenance.', v_name;
      END IF;
      -- And only for the same manager. Without this the restore hands a
      -- hand-set slot back to automation, which is worse than losing it.
      IF v_body !~ 'AND  i\.manager_employee_id = p\.manager_employee_id' THEN
        RAISE EXCEPTION 'MIG 855 FAILED: %() restores provenance without the same-manager test.', v_name;
      END IF;
      -- 853's guard must survive: it is what keeps the widened temp table safe.
      IF (SELECT count(*) FROM regexp_matches(v_body,
            'p\.removed_on = \(SELECT effective_from', 'g')) <> 2 THEN
        RAISE EXCEPTION 'MIG 855 FAILED: %() lost 853''s marker guard.', v_name;
      END IF;
    END;
  END LOOP;

  -- The Edit path must still refuse the wrong caller.
  SELECT pg_get_functiondef(p.oid) INTO v_name FROM pg_proc p
  WHERE  p.pronamespace = 'public'::regnamespace AND p.proname = 'admin_update_job_relationship_set';
  IF position('user_can' IN v_name) = 0 THEN
    RAISE EXCEPTION 'MIG 855 FAILED: admin_update lost its permission gate.';
  END IF;

  RAISE NOTICE 'MIG 855 OK: an Edit no longer takes a slot out of the lead-change sync.';
END $v$;

COMMIT;
