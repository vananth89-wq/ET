-- =============================================================================
-- Migration 839 — a project type says what it means, and cannot be deleted out
--                 from under the projects that use it
--
-- TWO FAULTS, BOTH IN THE SAME CORNER
-- ═══════════════════════════════════
--
-- 1. "BILLABLE" IS A POSITION, NOT A MEANING
--    755 seeded PROJECT_TYPE with ref_ids BILLABLE / INTERNAL / OVERHEAD. 760
--    recoded them to P001 / P002 / P003 to follow the house scheme (prefix plus
--    three digits, the same as D001 and T001), and said so plainly:
--
--        "Billable utilisation must match ref_id = 'P001', not 'BILLABLE'.
--         That is less self-describing, and it is the price of following the
--         convention rather than inventing a second one."
--
--    That price is now due. `generateRefId()` in ReferenceData.tsx hands out the
--    lowest unused slot, so P001 is whatever was created first — and on a
--    freshly seeded Prod it may not be Billable at all. Nothing anywhere fails
--    if it is not: `project_billability()` simply returns 'non_billable' for
--    every project, every utilisation figure drops, and no error is raised.
--
--    Worse, P001 ALREADY MEANS THREE DIFFERENT THINGS in this database:
--
--        PROJECT_TYPE  P001  ->  Billable
--        PROJECT_ROLE  P001  ->  EC Consultant     (mig 790)
--        ...and any picklist an admin creates whose name starts with P
--
--    Only the join decides which one a query is looking at. Every one of those
--    joins is correct today; none of them is correct BY CONSTRUCTION.
--
--    So the meaning moves onto the value itself: `meta->>'billable'`. It is an
--    admin-editable checkbox rather than a hidden system flag, which is the
--    whole point of 755 — the values belong to Reference Data. And it can say
--    something P001 never could: that TWO types are both chargeable, which any
--    company running "T&M" alongside "Fixed price" needs.
--
-- 2. THE DELETE GUARD IS THE ONLY GUARD, AND IT DOES NOT LOOK AT PROJECTS
--    `plIsInUse()` scans the loaded `employees` array for anything stringifying
--    to the value's id, ref_id or code. That is all it scans. So "Billable",
--    with 13 projects pointing at it, passes the guard — and then:
--
--        projects.project_type_id ... ON DELETE SET NULL
--
--    The delete SUCCEEDS. Thirteen projects are silently unclassified, every
--    billable figure in the system moves, and there is no error and no audit
--    row to explain it. `project_members.role_id` got ON DELETE RESTRICT when
--    790 added it; this column never did.
--
--    Both halves are fixed here, in that order of importance:
--      * the FK becomes RESTRICT, so the DATABASE refuses it. A guard in a
--        screen is advice; a constraint is a rule.
--      * `picklist_value_usage()` asks the CATALOG which tables point at a
--        value, so the screen can say WHICH 13 projects instead of failing with
--        a foreign key error. It finds FKs added in future migrations without
--        anyone remembering to update it.
--
--    The employees half stays in the client, because it cannot be derived: those
--    columns are TEXT with no FK to follow (employees.designation holds 'D001'),
--    so no catalog walk can see them.
--
-- WHAT THIS MIGRATION MUST NOT DO
--   Move a single project between classes. The flag is backfilled FROM the
--   current P001, and the verification below compares every project's class
--   before and after, row by row. If one moves, nothing commits.
--
-- Depends on: 755, 760 (PROJECT_TYPE), 790 (PROJECT_ROLE P001), 825
--             (project_billability), 770 + 837 (project summary)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0 — what every project is worth RIGHT NOW
-- ═══════════════════════════════════════════════════════════════════════════
-- Taken before anything moves, compared at the bottom. A migration that claims
-- to be behaviour-preserving should be made to prove it on the real data rather
-- than on the author's reading of it.

CREATE TEMP TABLE _mig839_before ON COMMIT DROP AS
SELECT b.id, b.cls FROM project_billability() b;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — the meaning moves onto the value
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n integer;
BEGIN
  -- Backfilled from the CURRENT truth, whatever that is on this database:
  -- the PROJECT_TYPE value presently coded P001. Not from the label 'Billable',
  -- which an admin may have renamed — that is precisely the thing 755 made
  -- editable, and matching on it would be the mistake this migration exists to
  -- stop making.
  UPDATE picklist_values pv
     SET meta = COALESCE(pv.meta, '{}'::jsonb) || jsonb_build_object('billable', 'true')
    FROM picklists p
   WHERE p.id = pv.picklist_id
     AND p.picklist_id = 'PROJECT_TYPE'
     AND pv.ref_id = 'P001'
     AND COALESCE(pv.meta->>'billable', '') <> 'true';

  GET DIAGNOSTICS v_n = ROW_COUNT;

  SELECT count(*) INTO v_n
  FROM   picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
  WHERE  p.picklist_id = 'PROJECT_TYPE' AND pv.meta->>'billable' = 'true';

  IF v_n = 0 THEN
    RAISE EXCEPTION 'MIG 839: no PROJECT_TYPE value is marked billable, and none was coded P001 to backfill from. Set the flag by hand before deploying — a database where nothing is billable reports 0%% utilisation without an error.';
  END IF;

  RAISE NOTICE 'MIG 839: % PROJECT_TYPE value(s) carry the billable flag.', v_n;
END;
$mig$;

-- The admin can see and change it. `type: boolean` is a checkbox in Reference
-- Data; more than one value may carry it, because more than one kind of work
-- can be chargeable.
UPDATE picklists
   SET meta_fields = '[{"key":"billable","label":"Chargeable to a client","type":"boolean","width":190}]'::jsonb
 WHERE picklist_id = 'PROJECT_TYPE'
   AND meta_fields IS DISTINCT FROM
       '[{"key":"billable","label":"Chargeable to a client","type":"boolean","width":190}]'::jsonb;

COMMENT ON COLUMN picklist_values.meta IS
  'Per-value extras, shaped by the picklist''s meta_fields. Mig 839: on '
  'PROJECT_TYPE, meta->>''billable'' = ''true'' is what makes a project''s hours '
  'chargeable. It replaced ref_id = ''P001'', which was a SEQUENCE NUMBER — the '
  'same code means EC Consultant on PROJECT_ROLE — and would have meant nothing '
  'on a differently seeded database.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the one definition reads the flag
-- ═══════════════════════════════════════════════════════════════════════════
-- 825 is the last definition of both, and 826 only CALLS them, so a full
-- replace here loses nothing. billable_project_ids() already delegates and is
-- reproduced unchanged rather than left to drift.

CREATE OR REPLACE FUNCTION public.project_billability()
RETURNS TABLE (id uuid, cls text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- Mig 839: the value's own flag, not its position in the list.
  SELECT p.id,
         CASE WHEN pv.meta->>'billable' = 'true' THEN 'billable'
              WHEN pv.id IS NULL                 THEN 'unclassified'
              ELSE 'non_billable' END
  FROM   projects p
  LEFT   JOIN picklist_values pv ON pv.id = p.project_type_id
$fn$;

REVOKE ALL ON FUNCTION public.project_billability() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_billability() TO authenticated;

COMMENT ON FUNCTION public.project_billability() IS
  'Mig 825, re-based by 839: every project and one of three words -- billable '
  '(the type carries meta->>''billable''), non_billable, or unclassified (no '
  'type set). The same three words and the same precedence as '
  'timesheet_report_utilisation, so a screen reading this and the report '
  'reading that cannot disagree about the same hour.';

-- NOTE the second condition changed from `pv.ref_id IS NULL` to `pv.id IS NULL`.
-- They were equivalent only while every PROJECT_TYPE row had a ref_id. A value
-- created with the flag ticked but no ref_id would have read as UNCLASSIFIED
-- under the old test even though it is plainly typed. `pv.id IS NULL` says the
-- thing actually meant: the LEFT JOIN found no type.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — the two reports
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._mig839_patch(
  p_fn text, p_a text, p_b text, p_expect integer, p_done text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_src text; v_new text; v_hits integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;
  IF v_n = 0 THEN RAISE EXCEPTION 'MIG 839: %() not found.', p_fn; END IF;
  IF v_n > 1 THEN RAISE EXCEPTION 'MIG 839: %() is overloaded % ways.', p_fn, v_n; END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  -- "Already applied" needs a marker that is ABSENT before and PRESENT after.
  -- The replacement is usually that marker, but not when it CONTAINS its own
  -- anchor: the CTE patch below keeps `AS type_ref,` and adds a column beside
  -- it, so testing for the replacement would never fire and a second run would
  -- add the column twice. p_done names the marker in that case.
  IF position(COALESCE(p_done, p_b) IN v_src) > 0
     AND (p_done IS NOT NULL OR position(p_a IN v_src) = 0) THEN
    RAISE NOTICE 'MIG 839: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 839: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 80);
  END IF;

  EXECUTE replace(v_src, p_a, p_b);
  RAISE NOTICE 'MIG 839: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

-- The utilisation classifier is patched by SHAPE, not by a counted anchor.
--
-- The first version of this migration asserted one `pv.ref_id = 'P001'` and one
-- `pv.ref_id <> 'P001'`, reconstructed from reading 820/822/836. The live
-- function has no `= 'P001'` arm at all -- for a P001 project, billable-vs-not
-- is decided per ACTIVITY by 821, so the only P001 test is the `<>` one that
-- sorts internal work out. The deploy failed on the count, which is the
-- assertion doing its job, and cost a round trip that reading the function
-- would have saved.
--
-- So: both forms are rewritten wherever they appear, zero occurrences of either
-- being acceptable, and the STRICT check moves to where it belongs -- that when
-- this is finished NO function decides billability by ref_id, that both reports
-- still run, and that not one project changed class. Those three together are
-- stronger than a per-arm count and do not depend on my reading of anything.
CREATE OR REPLACE FUNCTION public._mig839_rebase(p_fn text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_src text; v_new text;
  -- A ref_id or type_ref compared against a P-code: the thing that decides
  -- something by position. Prose mentioning P001 is not that.
  v_code CONSTANT text := '(ref_id|type_ref)[[:space:]]*(=|<>|!=)[[:space:]]*''P[0-9]';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;
  IF v_src IS NULL THEN RAISE EXCEPTION 'MIG 839: %() not found.', p_fn; END IF;

  -- Match the COMPARISON, never the bare string. 836 inserted a comment saying
  -- "the billable question is only put on a P001 project", and a test for the
  -- characters P001 cannot tell that apart from code that acts on them -- it
  -- would refuse to run, or refuse to believe it had finished, over prose.
  IF v_src !~ v_code THEN
    RAISE NOTICE 'MIG 839: %() already reads the flag, skipping.', p_fn;
    RETURN;
  END IF;

  -- IS DISTINCT FROM rather than <>, because meta is NULL on a value nobody has
  -- ticked and `NULL <> 'true'` is NULL -- which in a CASE falls through to the
  -- next arm without saying so.
  v_new := replace(v_src, 'pv.ref_id = ''P001''',  '(pv.meta->>''billable'') = ''true''');
  v_new := replace(v_new, 'pv.ref_id <> ''P001''', '(pv.meta->>''billable'') IS DISTINCT FROM ''true''');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'MIG 839: %() contains P001 but in neither form this migration knows how to rewrite. Read it before editing this file.', p_fn;
  END IF;
  IF v_new ~ v_code THEN
    RAISE EXCEPTION 'MIG 839: %() still DECIDES something by comparing a code to P-something after rewriting. There is a third form in there this migration does not know.', p_fn;
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'MIG 839: rebased %() onto the billable flag.', p_fn;
END;
$$;

DO $mig$
BEGIN
  PERFORM public._mig839_rebase('timesheet_report_utilisation');

  -- ── Project summary ──────────────────────────────────────────────────────
  -- Only billable_minutes and unclassified_minutes are read by the screen.
  -- internal_minutes and overhead_minutes are computed, keyed on P002 and P003,
  -- and displayed nowhere -- two more positional constants that would silently
  -- become zero on a differently seeded database, for figures nobody sees. They
  -- are removed rather than left in the payload as lies.
  -- The CTE has to carry the flag before anything can filter on it. type_ref
  -- stays -- it is still shown per row; it is just no longer allowed to DECIDE.
  PERFORM public._mig839_patch('timesheet_report_project_summary',
'           pv.ref_id       AS type_ref,',
'           pv.ref_id       AS type_ref,
           (pv.meta->>''billable'') = ''true'' AS type_billable,',
    1, 'AS type_billable');

  PERFORM public._mig839_patch('timesheet_report_project_summary',
'      ''billable_minutes'',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = ''P001''), 0) FROM ranked),
      ''internal_minutes'',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = ''P002''), 0) FROM ranked),
      ''overhead_minutes'',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_ref = ''P003''), 0) FROM ranked),',
'      -- Mig 839: the flag, not the position. type_ref still rides along per row
      -- for display; it is no longer allowed to DECIDE anything.
      ''billable_minutes'',     (SELECT COALESCE(sum(recorded_minutes) FILTER (WHERE type_billable), 0) FROM ranked),',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig839_patch(text, text, text, integer, text);
DROP FUNCTION IF EXISTS public._mig839_rebase(text);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — the database refuses what the screen misses
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_project_type_id_fkey;
ALTER TABLE projects ADD  CONSTRAINT projects_project_type_id_fkey
  FOREIGN KEY (project_type_id) REFERENCES picklist_values(id) ON DELETE RESTRICT;

COMMENT ON COLUMN projects.project_type_id IS
  'The PROJECT_TYPE picklist value. Mig 839 made this ON DELETE RESTRICT: it was '
  'SET NULL, so deleting a type SUCCEEDED and silently unclassified every project '
  'on it. Deactivate a type instead -- that is what `active` is for, and it '
  'leaves the projects that already used it describing themselves correctly.';

-- Which tables actually point at a value. Read from pg_constraint rather than a
-- hand-kept list, so a foreign key added by a future migration is covered the
-- day it exists instead of the day somebody remembers this function.
--
-- It cannot see references stored as TEXT -- employees.designation holds 'D001'
-- with no FK -- so the screen keeps its own scan for those. Two halves, and the
-- half that can be derived is derived.
CREATE OR REPLACE FUNCTION public.picklist_value_usage(p_value_id uuid)
RETURNS TABLE (table_name text, column_name text, row_count bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n bigint;
BEGIN
  IF NOT has_role('admin') THEN
    RAISE EXCEPTION 'Not permitted.' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR r IN
    SELECT c.conrelid::regclass::text AS tbl, a.attname::text AS col
    FROM   pg_constraint c
    JOIN   pg_class      rel ON rel.oid = c.confrelid
    JOIN   pg_namespace  n   ON n.oid   = rel.relnamespace
    CROSS  JOIN LATERAL unnest(c.conkey) AS k(attnum)
    JOIN   pg_attribute  a   ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE  c.contype = 'f'
      AND  n.nspname  = 'public'
      AND  rel.relname = 'picklist_values'
    ORDER  BY 1, 2
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1', r.tbl, r.col)
      INTO v_n USING p_value_id;
    IF v_n > 0 THEN
      table_name := r.tbl; column_name := r.col; row_count := v_n;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.picklist_value_usage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.picklist_value_usage(uuid) TO authenticated;

COMMENT ON FUNCTION public.picklist_value_usage(uuid) IS
  'Mig 839: every table and column with a FOREIGN KEY to picklist_values that '
  'actually holds this value, with counts. Derived from pg_constraint, so it '
  'covers keys added later without being edited. Does NOT cover values stored as '
  'plain text (employees.designation and friends) -- there is no key to follow, '
  'and the Reference Data screen scans those itself.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_bad integer; v_src text; v_del text;
BEGIN
  -- ── not one project may have changed class ───────────────────────────────
  SELECT count(*) INTO v_bad
  FROM   _mig839_before b
  FULL   JOIN project_billability() a ON a.id = b.id
  WHERE  a.id IS NULL OR b.id IS NULL OR a.cls IS DISTINCT FROM b.cls;

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'MIG 839 FAILED: % project(s) changed billability class. The flag was backfilled onto the wrong value, or a report arm was mis-patched.', v_bad;
  END IF;

  -- ── nothing decides billability by position any more ─────────────────────
  FOR v_src IN
    SELECT p.proname
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('project_billability', 'billable_project_ids',
                         'timesheet_report_utilisation', 'timesheet_report_project_summary')
      -- The comparison, not the characters: a comment that MENTIONS P001 is
      -- fine and 836 left one behind. Code that BRANCHES on it is not.
      AND  pg_get_functiondef(p.oid) ~ '(ref_id|type_ref)[[:space:]]*(=|<>|!=)[[:space:]]*''P[0-9]'
  LOOP
    RAISE EXCEPTION 'MIG 839 FAILED: %() still decides by a P-code. On a database seeded in a different order that code means something else entirely.', v_src;
  END LOOP;

  IF (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname='public' AND p.proname='project_billability') NOT LIKE '%meta->>''billable''%' THEN
    RAISE EXCEPTION 'MIG 839 FAILED: project_billability does not read the flag.';
  END IF;

  -- ── the FK actually refuses ──────────────────────────────────────────────
  SELECT confdeltype INTO v_del FROM pg_constraint
   WHERE conname = 'projects_project_type_id_fkey';
  IF v_del IS DISTINCT FROM 'r' THEN
    RAISE EXCEPTION 'MIG 839 FAILED: projects.project_type_id is delete-action "%", not RESTRICT. Deleting a type would still unclassify its projects in silence.', v_del;
  END IF;

  -- ── and the admin can reach the flag ─────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM picklists
                  WHERE picklist_id = 'PROJECT_TYPE'
                    AND meta_fields @> '[{"key":"billable"}]'::jsonb) THEN
    RAISE EXCEPTION 'MIG 839 FAILED: PROJECT_TYPE has no billable meta field, so the flag would be invisible and uneditable in Reference Data.';
  END IF;

  -- ── the patched reports must actually RUN ────────────────────────────────
  -- plpgsql does not parse a body when it is replaced, so a mis-patched
  -- function reports success here and fails the first time somebody opens the
  -- report. The first version of this migration did exactly that: it filtered
  -- on a column the CTE did not select, and every check above still passed.
  PERFORM timesheet_report_utilisation('{}'::jsonb);
  PERFORM timesheet_report_project_summary('{}'::jsonb);

  RAISE NOTICE 'MIG 839 OK: billability is a flag, the FK restricts, both reports run, and every project kept its class.';
END;
$v$;

COMMIT;
