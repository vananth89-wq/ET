-- =============================================================================
-- Migration 828 — help given to two projects on one day is two entries
--
-- THE DEFECT
-- ══════════
-- Mig 726 keyed an entry on (header, date, time type, project) NULLS NOT
-- DISTINCT — one row per project per day, and NULLS NOT DISTINCT so that rows
-- with no project are covered rather than exempt. That was right for what
-- existed then.
--
-- Mig 801 then made support entries book to NO project: the id the employee
-- chose goes to related_project_id and project_id is left NULL, which is what
-- keeps those hours out of the helped project's utilisation, burn and cost.
--
-- Put together, every support entry on a given day has project_id NULL and the
-- same time type, so they all collapse onto ONE key:
--
--     Key (header_id, entry_date, time_type_id, project_id)=(…, …, …, null)
--
-- Help AZAD in the morning and AMPTJ in the afternoon and the second is refused
-- with a constraint violation. Not a merge, not a warning -- a raw duplicate key
-- error, on a perfectly ordinary thing to do.
--
-- WHAT MAKES THIS ONE WORTH READING ABOUT
--   Mig 802 wrote down this exact reasoning -- "every support entry has
--   project_id NULL, so two helps to different projects on one day read as the
--   same entry" -- and used it to widen Copy Day's runtime collision key. The
--   index underneath was never touched. So paste now correctly decides the two
--   are different and then the write fails on the constraint it was reasoning
--   around. The analysis was right and was applied to one layer of two.
--
-- THREE LOOKUPS SHARE THE BLIND SPOT
--   An index is not the only thing that identifies an entry. Three queries find
--   "the existing entry for this day/type/project" and none of them can tell two
--   support entries apart, so each finds whichever row came first:
--
--     save_timesheet_entry            the ALREADY_EXISTS / append lookup
--     bulk_create_timesheet_entries   the clash test, and the append arm
--
--   Fixing the index alone would trade a hard error for a silent wrong answer,
--   which is the worse of the two. They go together.
--
-- WHY help_requested_by IS IN THE KEY TOO
--   Mig 829 adds it: who on the helped project asked. Two people asking you for
--   help on one project on one day is two facts, and one key would merge them
--   and lose a requester -- the same argument 824 made about one activity name
--   carrying two billable answers. The column is added HERE, unused, so the
--   index is built once and 829 does not have to rebuild it. A nullable column
--   nobody reads yet cannot break anyone (mig 745's argument for activity_rows).
--
-- SAFE ON EXISTING DATA
--   The new key is strictly WIDER than the old one. Every pair of rows that was
--   distinct before is still distinct, so no existing row can collide and the
--   index cannot fail to build. Verified below by building it and checking it
--   is valid rather than by assuming.
--
-- Depends on : 726 (the index), 729 (bulk), 733 (save), 801 (related_project_id)
-- =============================================================================

BEGIN;

-- ── 1. The column the key will need ──────────────────────────────────────────
--
-- Added here rather than in 829 so the index is built once. Nothing reads it
-- until 829; nothing writes it either, so every row has NULL and the widened
-- key behaves exactly as if only related_project_id had been added.

ALTER TABLE public.timesheet_entries
  ADD COLUMN IF NOT EXISTS help_requested_by uuid REFERENCES public.employees(id);

COMMENT ON COLUMN public.timesheet_entries.help_requested_by IS
  'Mig 828/829: the employee who asked for this help. Set only where the time '
  'type records help given to another project; NULL everywhere else, and NULL '
  'on every row recorded before 829. In the entry key because two people asking '
  'for help on one project on one day are two facts.';


-- ── 2. The key ───────────────────────────────────────────────────────────────

DROP INDEX IF EXISTS public.ux_timesheet_entries_day_type_project;

CREATE UNIQUE INDEX IF NOT EXISTS ux_timesheet_entries_day_type_project
  ON public.timesheet_entries
     (header_id, entry_date, time_type_id, project_id, related_project_id, help_requested_by)
  NULLS NOT DISTINCT;

COMMENT ON INDEX public.ux_timesheet_entries_day_type_project IS
  'Mig 726, widened by 828: one entry per (timesheet, date, time type, project, '
  'HELPED project, requester). The last two exist because a support entry books '
  'to no project (801), so without them every help given on one day shares one '
  'key and only the first can be recorded. NULLS NOT DISTINCT still, so rows '
  'with no project are covered by the rule rather than exempt from it.';


-- ── 3. The three lookups that cannot tell two helps apart ────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_fn text; v_want integer;

  -- Both write paths spell it the same way, with the same padding, because 729
  -- wrote one and 733 copied it. Asserted per function rather than assumed:
  -- see prowess-in-place-function-patching on what "the same code" is worth.
  a_key CONSTANT text :=
'      AND  e.project_id   IS NOT DISTINCT FROM v_proj_id;';
  b_key CONSTANT text :=
'      AND  e.project_id   IS NOT DISTINCT FROM v_proj_id' || E'\n' ||
'      -- mig 828. A support entry books to no project, so on the old test' || E'\n' ||
'      -- every help given on one day looked like the same entry and this' || E'\n' ||
'      -- found whichever came first -- appending somebody else''''s hours to it.' || E'\n' ||
'      AND  e.related_project_id IS NOT DISTINCT FROM v_rel_id;';

  -- The append arm in bulk is indented differently from the clash test above
  -- it. Same statement, one space out, which is exactly the shape that makes a
  -- single literal match one and miss the other.
  a_key2 CONSTANT text :=
'         AND e.project_id   IS NOT DISTINCT FROM v_proj_id;';
  b_key2 CONSTANT text :=
'         AND e.project_id   IS NOT DISTINCT FROM v_proj_id' || E'\n' ||
'         -- mig 828, as above: without this the append arm reopens whichever' || E'\n' ||
'         -- support entry came first, whatever project it was helping.' || E'\n' ||
'         AND e.related_project_id IS NOT DISTINCT FROM v_rel_id;';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['save_timesheet_entry', 'bulk_create_timesheet_entries']
  LOOP
    SELECT count(*) INTO v_hits
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 828: % has % overloads, expected 1.', v_fn, v_hits;
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 828: mig 801 must run first -- % does not route a related project.', v_fn;
    END IF;
    IF position('mig 828' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 828: % already tells two helps apart. Nothing to do.', v_fn;
      CONTINUE;
    END IF;

    v_new := v_src;

    -- save has one of these; bulk has one of each shape.
    v_want := CASE WHEN v_fn = 'save_timesheet_entry' THEN 1 ELSE 1 END;

    v_hits := (length(v_new) - length(replace(v_new, a_key, ''))) / length(a_key);
    IF v_hits <> v_want THEN
      RAISE EXCEPTION 'MIG 828: the entry lookup matched % times in %, expected %.', v_hits, v_fn, v_want;
    END IF;
    v_new := replace(v_new, a_key, b_key);

    IF v_fn = 'bulk_create_timesheet_entries' THEN
      v_hits := (length(v_new) - length(replace(v_new, a_key2, ''))) / length(a_key2);
      IF v_hits <> 1 THEN
        RAISE EXCEPTION 'MIG 828: the append lookup matched % times in %, expected 1.', v_hits, v_fn;
      END IF;
      v_new := replace(v_new, a_key2, b_key2);
    END IF;

    -- The rules that must survive.
    IF position('v_bill_applies' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 828: the billable rule (821) was lost from %.', v_fn;
    END IF;
    IF position('billable boolean' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 828: the activity fold (824) was lost from %.', v_fn;
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'MIG 828: % now tells two helps on one day apart.', v_fn;
  END LOOP;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_def text;
  v_src text;
  v_name text;
  n integer;
BEGIN
  -- ── The index ─────────────────────────────────────────────────────────────
  SELECT pg_get_indexdef(i.indexrelid) INTO v_def
  FROM   pg_index i JOIN pg_class c ON c.oid = i.indexrelid
  WHERE  c.relname = 'ux_timesheet_entries_day_type_project';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'MIG 828 FAILED: the entry index is missing. Dropping it and failing to rebuild would let a day hold two identical entries.';
  END IF;
  IF position('related_project_id' IN v_def) = 0 THEN
    RAISE EXCEPTION 'MIG 828 FAILED: the index still ignores the helped project, so only one help a day can be recorded.';
  END IF;
  IF position('help_requested_by' IN v_def) = 0 THEN
    RAISE EXCEPTION 'MIG 828 FAILED: the index does not carry the requester, and 829 would have to rebuild it.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                 WHERE c.relname = 'ux_timesheet_entries_day_type_project' AND i.indnullsnotdistinct) THEN
    RAISE EXCEPTION 'MIG 828 FAILED: the index is NULLS DISTINCT. Every entry with no project would be exempt from the rule -- which is the case 726 added it for.';
  END IF;
  -- Built, not merely defined. A unique index over existing data can fail; this
  -- one cannot, because the key is strictly wider than the one it replaces --
  -- but "cannot" is worth checking rather than asserting.
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                 WHERE c.relname = 'ux_timesheet_entries_day_type_project'
                   AND i.indisvalid AND i.indisready) THEN
    RAISE EXCEPTION 'MIG 828 FAILED: the index is not valid and ready.';
  END IF;

  -- ── The column ────────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'timesheet_entries'
                   AND column_name = 'help_requested_by') THEN
    RAISE EXCEPTION 'MIG 828 FAILED: help_requested_by was not added.';
  END IF;
  -- Nobody writes it yet. If a row already carries one, something has run out
  -- of order and the index was built on an assumption that no longer holds.
  SELECT count(*) INTO n FROM timesheet_entries WHERE help_requested_by IS NOT NULL;
  IF n > 0 THEN
    RAISE NOTICE 'MIG 828: % row(s) already carry a requester. Expected 0 until mig 829 -- not fatal, but worth knowing.', n;
  END IF;

  -- ── The lookups ───────────────────────────────────────────────────────────
  FOR v_name, v_src IN
    SELECT p.proname, pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    SELECT count(*) INTO n
    FROM   regexp_matches(v_src, 'e\.related_project_id IS NOT DISTINCT FROM v_rel_id', 'g');
    IF n < 1 THEN
      RAISE EXCEPTION 'MIG 828 FAILED: % still identifies an entry without the helped project.', v_name;
    END IF;
    IF v_name = 'bulk_create_timesheet_entries' AND n <> 2 THEN
      RAISE EXCEPTION 'MIG 828 FAILED: bulk has % of the 2 lookups fixed. The clash test and the append arm are different statements and both decide which entry you are writing to.', n;
    END IF;
  END LOOP;

  -- Copy Day already carried this reasoning (802) and must not have lost it.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';
  IF position('e.related_project_id IS NOT DISTINCT FROM r.related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 828 FAILED: paste_timesheet_day lost mig 802''s collision key.';
  END IF;

  RAISE NOTICE 'Migration 828 verified: the entry key carries the helped project and the requester, and all three lookups can tell two helps on one day apart.';
END $mig$;

COMMIT;
