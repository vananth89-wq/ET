-- =============================================================================
-- Migration 795: the overlap test reads the end date you actually typed
--
-- THE BUG
-- ═══════
-- Migration 792 gave project_member_add() an end date. It updated the
-- signature, the DECLARE, the INSERT and the VALUES -- and missed the friendly
-- overlap pre-check sitting above them, which still reads:
--
--     && daterange(p_effective_from, 'infinity'::date, '[]')
--
-- So every add is tested as though the new assignment ran forever. Two
-- consequences, one of them a flat refusal of legal data:
--
--   1. You cannot add somebody for a period that ENDS BEFORE an existing stint
--      begins. Alice runs 01 Nov -> open; adding her 01 Aug -> 30 Sep is
--      refused, although the two never touch. The EXCLUDE constraint behind it
--      would have allowed it -- this is the courtesy check being stricter than
--      the rule it exists to explain.
--
--   2. The refusal names the wrong remedy. "End the current assignment first"
--      is advice about a live assignment, but the clash is just as often with
--      one that ended months ago, where the fix is to start later instead.
--      The screen offers no way to see which stint is in the way -- past
--      members are behind a toggle and the message names neither dates nor
--      person.
--
-- THE FIX
-- ───────
-- Test the range the INSERT is actually going to write: p_effective_to when
-- given, else the project's end date, else infinity -- the same COALESCE ladder
-- 792 built for v_to, spelled inline so the check keeps working where it
-- stands, ahead of that assignment.
--
-- Then say which stint is in the way, and what to do about it:
--
--   "That person is already on this project from 01 Feb 2026 to 20 Aug 2026.
--    Start the new assignment on or after 21 Aug 2026, or change that one."
--
--   "That person is already on this project from 01 Feb 2026, with no end date.
--    End that assignment first if they are rejoining."
--
-- WHAT IS NOT CHANGED
-- ───────────────────
-- The EXCLUDE constraint on project_members. It was always right; only the
-- sentence in front of it was wrong. project_member_update()'s own overlap
-- check already compares the new dates (786) and is left alone.
--
-- CHANGES
-- ───────
--   project_member_add()   -- overlap test honours the end date; names the clash
-- =============================================================================

SET jit = 'off';

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_dec text := E'DECLARE\n  v_id uuid;\n';
  r_dec text := E'DECLARE\n  v_id uuid;\n  v_ceil  date;\n  v_cfrom date;\n  v_cto   date;\n';

  a_chk text :=
       E'  -- Caught here so the user reads a sentence rather than an exclusion-constraint\n'
    || E'  -- violation. The constraint still stands behind it.\n'
    || E'  IF EXISTS (\n'
    || E'    SELECT 1 FROM project_members pm\n'
    || E'    WHERE  pm.project_id = p_project_id\n'
    || E'      AND  pm.employee_id = p_employee_id\n'
    || E'      AND  daterange(pm.effective_from, COALESCE(pm.effective_to, ''infinity''::date), ''[]'')\n'
    || E'           && daterange(p_effective_from, ''infinity''::date, ''[]'')\n'
    || E'  ) THEN\n'
    || E'    RETURN jsonb_build_object(''ok'', false, ''error'', ''ALREADY_ON_PROJECT'',\n'
    || E'      ''message'', ''That person is already on this project for an overlapping period. ''\n'
    || E'                 ''End the current assignment first if they are rejoining.'');\n'
    || E'  END IF;\n';

  r_chk text :=
       E'  -- Caught here so the user reads a sentence rather than an exclusion-constraint\n'
    || E'  -- violation. The constraint still stands behind it.\n'
    || E'  --\n'
    || E'  -- Mig 795: test the range the INSERT will actually write. Before this the\n'
    || E'  -- new stint was compared as though it ran to infinity, so an assignment\n'
    || E'  -- that ends in September was refused against one that starts in November.\n'
    || E'  -- The COALESCE ladder is 792''s, spelled here because this check runs\n'
    || E'  -- ahead of the line that fills v_to.\n'
    || E'  SELECT COALESCE(p_effective_to, p.end_date, ''infinity''::date) INTO v_ceil\n'
    || E'  FROM   projects p WHERE p.id = p_project_id;\n'
    || E'\n'
    || E'  -- Crossed dates would make daterange() raise a bare error here, ahead of\n'
    || E'  -- the DATES_CROSSED check below that says it in words. Let that one speak.\n'
    || E'  IF v_ceil IS NOT NULL AND v_ceil >= p_effective_from THEN\n'
    || E'    SELECT pm.effective_from, pm.effective_to INTO v_cfrom, v_cto\n'
    || E'    FROM   project_members pm\n'
    || E'    WHERE  pm.project_id = p_project_id\n'
    || E'      AND  pm.employee_id = p_employee_id\n'
    || E'      AND  daterange(pm.effective_from, COALESCE(pm.effective_to, ''infinity''::date), ''[]'')\n'
    || E'           && daterange(p_effective_from, v_ceil, ''[]'')\n'
    || E'    ORDER  BY pm.effective_from\n'
    || E'    LIMIT  1;\n'
    || E'\n'
    || E'    IF FOUND THEN\n'
    || E'      -- Name the stint in the way. "End the current assignment first" was\n'
    || E'      -- advice about a live row, and the clash is as often with a closed one\n'
    || E'      -- -- where the fix is to start later, not to end anything.\n'
    || E'      RETURN jsonb_build_object(''ok'', false, ''error'', ''ALREADY_ON_PROJECT'',\n'
    || E'        ''message'', CASE WHEN v_cto IS NULL\n'
    || E'          THEN format(''That person is already on this project from %s, with no end date. ''\n'
    || E'                      ''End that assignment first if they are rejoining.'',\n'
    || E'                      to_char(v_cfrom, ''DD Mon YYYY''))\n'
    || E'          ELSE format(''That person is already on this project from %s to %s. ''\n'
    || E'                      ''Start the new assignment on or after %s, or change that one.'',\n'
    || E'                      to_char(v_cfrom, ''DD Mon YYYY''), to_char(v_cto, ''DD Mon YYYY''),\n'
    || E'                      to_char(v_cto + 1, ''DD Mon YYYY''))\n'
    || E'        END);\n'
    || E'    END IF;\n'
    || E'  END IF;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 795: project_member_add not found';
  END IF;

  IF position('Start the new assignment on or after' in v_src) > 0 THEN
    RAISE NOTICE 'mig 795: the overlap test already reads the end date -- skipping';
    RETURN;
  END IF;

  -- 792 must have landed, or there is no p_effective_to to read.
  IF position('p_effective_to' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 795: project_member_add does not take an end date -- 792 has not run';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_dec, ''))) / NULLIF(length(a_dec), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 795: DECLARE anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a_dec, r_dec);

  v_hits := (length(v_new) - length(replace(v_new, a_chk, ''))) / NULLIF(length(a_chk), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 795: overlap-check anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_chk, r_chk);

  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION public.project_member_add(uuid, uuid, date, numeric, uuid, date) IS
  'Mig 774/789/790/791/792/795: staff somebody onto a project. Gated on '
  'can_staff_project(id, ''create''). Refuses a stint that crosses its own '
  'dates, outlives the project, or overlaps one this person already has -- the '
  'last of those naming the stint in the way. Announces the add, and never '
  'lets a failed announcement roll one back.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  -- The infinity literal on the CALLER's side is the bug. It must be gone.
  IF position(E'&& daterange(p_effective_from, ''infinity''::date' in v_src) > 0 THEN
    RAISE EXCEPTION 'mig 795: the overlap test still assumes the new stint never ends';
  END IF;

  IF position('p_effective_to' in v_src) = 0
     OR position(E'COALESCE(p_effective_to, p.end_date, ''infinity''::date)' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 795: the overlap test does not read p_effective_to';
  END IF;

  -- Crossed dates must still reach DATES_CROSSED rather than blowing up inside
  -- daterange(). The guard is what keeps that true.
  IF position('IF v_ceil IS NOT NULL AND v_ceil >= p_effective_from THEN' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 795: the overlap test is not guarded against a crossed range';
  END IF;

  -- The stint on the OTHER side is still open-ended-aware; losing that would
  -- let a new row slide under a live assignment with no end date.
  IF position(E'COALESCE(pm.effective_to, ''infinity''::date)' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 795: the existing stint no longer treats NULL as open-ended';
  END IF;

  IF position('End that assignment first if they are rejoining' in v_src) = 0
     OR position('Start the new assignment on or after' in v_src) = 0 THEN
    RAISE EXCEPTION 'mig 795: the refusal does not name the stint in the way';
  END IF;

  IF position('End the current assignment first if they are rejoining' in v_src) > 0 THEN
    RAISE EXCEPTION 'mig 795: the old one-size refusal survived';
  END IF;

  RAISE NOTICE 'mig 795: OK -- the overlap test reads the end date, and says what is in the way';
END $mig$;
