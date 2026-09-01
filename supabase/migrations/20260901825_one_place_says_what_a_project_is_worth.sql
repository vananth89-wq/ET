-- =============================================================================
-- Migration 825 — one place says whether a project's hours are chargeable
--
-- WHY 823 IS NOT ENOUGH
-- ════════════════════
-- 823 gave the timesheet screen `billable_project_ids()` so it knew when to
-- OFFER the per-activity billable question. That is a yes/no list, and yes/no is
-- one answer short of what the classification actually has:
--
--     P001              -> billable
--     P002 / P003 / …   -> non_billable
--     no type set       -> UNCLASSIFIED, and never assumed to be either
--
-- The Monthly Summary is about to show an employee their own billable split.
-- With a yes/no list it would have to fold "no type set" into non-billable,
-- while `timesheet_report_utilisation` (820, re-grained by 822) reports those
-- same hours as unclassified. Two screens, same hour, different word — and the
-- disagreement is what gets argued about, which is exactly the failure 820 was
-- written to end.
--
-- SO THE LIST GROWS A SECOND COLUMN, AND KEEPS ONE OWNER
-- ─────────────────────────────────────────────────────
-- `project_billability()` returns (id, cls) using the same three words and the
-- same precedence as the live classifier — which 822 owns, not 820: 822
-- replaced that branch outright when it moved the split to activity grain.
--
-- `billable_project_ids()` is not deleted and is not duplicated: it is redefined
-- as a filter over the new function, so there is exactly one statement in the
-- database that decides what P001 means.
-- Two functions answering the same question is how they drift; one answering it
-- and one narrowing it cannot.
--
--   Keeping 823's function alive also removes the deploy window. The database
--   and the frontend ship separately; a DROP here would break the live My
--   Timesheet screen for as long as the two were out of step.
--
-- LEFT JOIN, DELIBERATELY
--   823 used an inner join, so a project with no type simply fell out of the
--   list — which is right for "which projects should I ask about" and wrong for
--   "what is this project". Here the row must survive and say `unclassified`,
--   or the screen cannot tell an untyped project from one it has never heard of.
--
-- WHAT IT DISCLOSES
--   Nothing 823 did not. A commercial classification of projects, to someone who
--   can already see the project list and is being asked to reason about it. No
--   dates, no rates, no amounts, no hours.
--
-- NOT AN ENFORCEMENT POINT
--   Offers only. What is actually stored is decided by save_timesheet_entry and
--   bulk_create_timesheet_entries (821, 824), whatever a caller believes.
--
-- Depends on : 001 (picklist_values.ref_id, projects.project_type_id), 822, 823
-- =============================================================================

BEGIN;

-- ── 1. The classification ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.project_billability()
RETURNS TABLE (id uuid, cls text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT p.id,
         CASE WHEN pv.ref_id = 'P001' THEN 'billable'
              WHEN pv.ref_id IS NULL  THEN 'unclassified'
              ELSE 'non_billable' END
  FROM   projects p
  LEFT   JOIN picklist_values pv ON pv.id = p.project_type_id
$fn$;

REVOKE ALL ON FUNCTION public.project_billability() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_billability() TO authenticated;

COMMENT ON FUNCTION public.project_billability() IS
  'Mig 825: every project and one of three words -- billable (P001), '
  'non_billable, or unclassified (no type set). The same three words and the '
  'same precedence as timesheet_report_utilisation (820/822), so a screen reading '
  'this and the report reading that cannot disagree about the same hour. '
  'Offers only -- what is stored is decided by save_timesheet_entry and '
  'bulk_create_timesheet_entries (821, 824).';


-- ── 2. 823's list becomes a filter over it, not a second opinion ─────────────
--
-- Same signature and same OUT columns, so CREATE OR REPLACE is enough and every
-- existing caller keeps working through the deploy.

CREATE OR REPLACE FUNCTION public.billable_project_ids()
RETURNS TABLE (id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- mig 825. Delegates. The P001 test lives in project_billability() and
  -- nowhere else -- two functions each carrying their own copy is how they
  -- come to disagree, and the one that disagrees quietly is the one on screen.
  SELECT b.id FROM project_billability() b WHERE b.cls = 'billable'
$fn$;

REVOKE ALL ON FUNCTION public.billable_project_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.billable_project_ids() TO authenticated;

COMMENT ON FUNCTION public.billable_project_ids() IS
  'Mig 823, narrowed by 825: the ids of projects whose type is P001. Now a '
  'filter over project_billability() rather than its own copy of the rule. So '
  'the timesheet screen knows when to offer the per-activity billable choice.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src   text;
  v_cls   text;
  n       integer;
  n_a     integer;
  n_b     integer;
BEGIN
  -- ── The new function exists, answers only about projects, and is callable ──
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'project_billability';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 825 FAILED: project_billability was not created.';
  END IF;
  IF position('P001' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: the function does not test for P001.';
  END IF;
  IF position('hours_minutes' IN v_src) > 0 OR position('timesheet' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: it reads timesheet data. It answers a question about projects.';
  END IF;
  -- An inner join here would drop untyped projects instead of naming them,
  -- which is the whole reason this function exists rather than 823 alone.
  IF position('LEFT' IN upper(v_src)) = 0 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: the join is not a LEFT join, so an untyped project falls out of the list rather than reading as unclassified.';
  END IF;

  SELECT count(*) INTO n
  FROM   information_schema.routine_privileges
  WHERE  routine_schema = 'public' AND routine_name = 'project_billability'
    AND  grantee = 'authenticated' AND privilege_type = 'EXECUTE';
  IF n < 1 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: authenticated cannot execute project_billability.';
  END IF;

  -- ── Exactly three words, and no fourth ────────────────────────────────────
  -- A typo in one branch would ship a class no reader tests for, and the hours
  -- behind it would land in whatever the screen's else-branch happened to be.
  FOR v_cls IN SELECT DISTINCT b.cls FROM project_billability() b LOOP
    IF v_cls NOT IN ('billable', 'non_billable', 'unclassified') THEN
      RAISE EXCEPTION 'MIG 825 FAILED: project_billability returned an unknown class %.', v_cls;
    END IF;
  END LOOP;

  -- ── Every project is named exactly once ───────────────────────────────────
  -- A join fan-out would double a project's hours in any screen that sums by
  -- class, and nothing else here would notice.
  SELECT count(*) INTO n_a FROM project_billability();
  SELECT count(*) INTO n_b FROM projects;
  IF n_a <> n_b THEN
    RAISE EXCEPTION 'MIG 825 FAILED: % rows for % projects. The join is fanning out or dropping rows.', n_a, n_b;
  END IF;

  -- ── 823's list delegates, and the two agree ───────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'billable_project_ids';

  IF position('project_billability' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: billable_project_ids still carries its own copy of the P001 rule.';
  END IF;

  SELECT count(*) INTO n_a FROM billable_project_ids();
  SELECT count(*) INTO n_b FROM project_billability() b WHERE b.cls = 'billable';
  IF n_a <> n_b THEN
    RAISE EXCEPTION 'MIG 825 FAILED: billable_project_ids returns % ids, project_billability says % are billable.', n_a, n_b;
  END IF;

  -- ── The report this must never contradict is still asking the same thing ──
  --
  -- 822 owns the live classifier -- NOT 820, which 822 replaced branch and all.
  -- (Checked against 822's text, not 820's: anchoring on the older migration is
  --  how three deploys were lost this week. See prowess-in-place-function-
  --  patching.)
  --
  -- Deliberately SHORT anchors. A full-shape match would be exact today and
  -- brittle for ever, and would fail a migration replay the first time somebody
  -- reformats that CASE. These three catch the change that actually matters --
  -- the report ceasing to classify by project type at all -- and claim nothing
  -- more. The real guarantee is that this function and that one were written
  -- from the same three words, which is a fact about the code review, not
  -- something SQL can assert.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 825 FAILED: timesheet_report_utilisation not found.';
  END IF;
  IF position('pv.ref_id' IN v_src) = 0
     OR position('P001' IN v_src) = 0
     OR position('unclassified' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 825 FAILED: timesheet_report_utilisation no longer classifies hours by project type. The summary would report a split the report does not recognise.';
  END IF;

  SELECT count(*) INTO n FROM project_billability() b WHERE b.cls = 'unclassified';
  RAISE NOTICE 'Migration 825 verified: % projects classified -- % billable, % with no type set. billable_project_ids delegates, and the report still classifies by project type.', n_b + (SELECT count(*) FROM project_billability() c WHERE c.cls <> 'billable'), n_b, n;
END $mig$;

COMMIT;
