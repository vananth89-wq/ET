-- =============================================================================
-- Migration 820 — the project decides whether an hour is billable, not the
--                 time type that happens to carry it
--
-- THE DEFECT, AND HOW IT WAS FOUND
-- ════════════════════════════════
-- Migration 800 added a billable split to the utilisation report and classified
-- each hour with this precedence:
--
--     time_type_id IS NOT NULL  ->  classify by time_types.is_billable
--     project_id   IS NOT NULL  ->  classify by the project's type
--
-- The reasoning was that a requires_project entry (mig 715) is "a time-type
-- entry that happens to name a project", so the type should win. That is true
-- of Training-with-a-project. It is entirely wrong for how this product is
-- actually used, and two facts make it wrong:
--
--   1. save_timesheet_entry and bulk_create_timesheet_entries set
--          v_kind := CASE WHEN category = 'absence' THEN 'leave' ELSE 'time_type' END
--      and nothing anywhere writes entry_kind = 'project'. EVERY entry is a
--      time-type entry. The project branch above is dead code.
--
--   2. Ordinary project work is recorded on an attendance type with
--      requires_project = true -- "Work (WK)" on Dev. So every real hour hit
--      the first branch and was classified by a flag that mig 800 defaulted to
--      false on every existing type.
--
-- The result: totals.billable_split.billable_minutes was ZERO for all work, and
-- the Billable share tile read 0%. Not a rounding problem -- a number that was
-- wrong for every row, shipped, and only noticed on looking at a real timesheet
-- rather than at a fixture.
--
-- THE CORRECTION
-- ──────────────
-- Billability belongs to the PROJECT. It always did: picklist_values.ref_id via
-- projects.project_type_id, P001 billable / P002 internal / P003 overhead, which
-- is what timesheet_report_project_summary has classified by since 766 and has
-- been right about all along. The two reports disagreed, and the project-grained
-- one was the honest one.
--
--     absence                     -> absence       (leave is not worked time)
--     names a project             -> the project's type decides
--     no project, has a time type -> time_types.is_billable decides
--     neither                     -> unclassified
--
-- WHY THIS DOES NOT UNDO MIG 800
--   is_billable is still the right property and is still the answer for hours
--   with no project behind them -- Training, On-Site Visit, and support hours
--   (mig 801), which leave project_id NULL by design and so fall through to the
--   type exactly as intended. 800 put the flag on the right table; it only got
--   the order of the questions wrong.
--
-- WHAT THIS BRINGS INTO AGREEMENT
--   After this, timesheet_report_utilisation and
--   timesheet_report_project_summary classify the same hour the same way. Two
--   reports that disagree about revenue is worse than either being wrong,
--   because the disagreement is what gets argued about.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   744, 745, 746, 750, 752, 771 and 800 have each amended this function. The
--   anchor is the exact CASE mig 800 inserted, asserted to match once.
--
-- Depends on : 800
-- =============================================================================

BEGIN;

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_cls CONSTANT text :=
'                 CASE' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN tt.category = ''absence''       THEN ''absence''' || E'\n' ||
'                             WHEN COALESCE(tt.is_billable, false) THEN ''billable''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id = ''P001'' THEN ''billable''' || E'\n' ||
'                             WHEN pv.ref_id IS NULL    THEN ''unclassified''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   ELSE ''unclassified''' || E'\n' ||
'                 END AS cls' || E'\n';

  b_cls CONSTANT text :=
'                 -- mig 820. The PROJECT decides. Every entry in this product' || E'\n' ||
'                 -- is entry_kind = time_type -- nothing writes ''project'' --' || E'\n' ||
'                 -- and ordinary work is recorded on an attendance type with' || E'\n' ||
'                 -- requires_project, so testing the time type first sent every' || E'\n' ||
'                 -- real hour down a branch governed by a flag that defaults to' || E'\n' ||
'                 -- false. Billable share read 0% for the whole company.' || E'\n' ||
'                 --' || E'\n' ||
'                 -- Absence stays first: leave is not worked time whatever else' || E'\n' ||
'                 -- the row carries. The time type is the FALLBACK, which is' || E'\n' ||
'                 -- exactly right for the hours that have no project behind' || E'\n' ||
'                 -- them -- Training, On-Site Visit, and support hours (801),' || E'\n' ||
'                 -- which leave project_id NULL by design.' || E'\n' ||
'                 CASE' || E'\n' ||
'                   WHEN tt.category = ''absence'' THEN ''absence''' || E'\n' ||
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id = ''P001'' THEN ''billable''' || E'\n' ||
'                             WHEN pv.ref_id IS NULL    THEN ''unclassified''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN COALESCE(tt.is_billable, false) THEN ''billable''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   ELSE ''unclassified''' || E'\n' ||
'                 END AS cls' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 820: timesheet_report_utilisation not found.';
  END IF;
  IF position('billable_split' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820: mig 800 must run first -- there is no split to correct.';
  END IF;

  IF position('mig 820. The PROJECT decides' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 820: the precedence is already corrected. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_cls, ''))) / length(a_cls);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 820: the classification anchor matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_src, a_cls, b_cls);
    EXECUTE v_new;
    RAISE NOTICE 'MIG 820: billable classification now asks the project first.';
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  v_p   integer;
  v_t   integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  -- The project is asked before the time type. Positions, not presence: both
  -- branches exist either way, and the ORDER is the entire defect.
  v_p := position('WHEN en.project_id IS NOT NULL THEN' IN v_src);
  v_t := position('WHEN en.time_type_id IS NOT NULL THEN' IN v_src);
  IF v_p = 0 OR v_t = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: a classification branch is missing.';
  END IF;
  IF v_p > v_t THEN
    RAISE EXCEPTION 'MIG 820 FAILED: the time type is still asked before the project.';
  END IF;

  -- Absence is asked before either, or leave taken on a project-linked type
  -- would be classified as work.
  IF position('WHEN tt.category = ''absence'' THEN ''absence''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: absence is no longer its own bucket.';
  END IF;
  IF position('WHEN tt.category = ''absence'' THEN ''absence''' IN v_src) > v_p THEN
    RAISE EXCEPTION 'MIG 820 FAILED: absence is asked after the project.';
  END IF;

  -- The fallback is intact: hours with no project still read the flag 800 added.
  IF position('COALESCE(tt.is_billable, false)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: is_billable is no longer consulted at all. It is still the answer for hours with no project.';
  END IF;

  -- An untyped project is still unclassified rather than assumed billable.
  IF position('WHEN pv.ref_id IS NULL    THEN ''unclassified''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: an untyped project is no longer reported as unclassified.';
  END IF;

  -- And nothing else in the function moved.
  IF position('billable_split' IN v_src) = 0
     OR position('''absence_minutes''' IN v_src) = 0
     OR position('''unclassified_minutes''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: the four buckets are no longer all reported.';
  END IF;
  IF position('''recorded_minutes'', (SELECT COALESCE(sum(hours_minutes), 0) FROM ent)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: recorded_minutes was altered. This migration reclassifies; it must not re-total.';
  END IF;
  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 820 FAILED: the function lost the PM predicate (771).';
  END IF;

  RAISE NOTICE 'Migration 820 verified: the project is asked first, absence before that, the time type is the fallback, and recorded_minutes is untouched.';
END $mig$;

COMMIT;
