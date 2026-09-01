-- =============================================================================
-- Migration 823 — the screen can ask which projects are billable
--
-- 821 refuses an unanswered activity on a billable project and clears the flag
-- everywhere else, so the RULE is enforced server-side and cannot be talked out
-- of. But the timesheet screen still has to know when to OFFER the question,
-- and it cannot: my_timesheet_projects returns id, name, dates and membership,
-- and says nothing about the project's type.
--
-- Without this the screen has two failure modes, both bad:
--   offer it where it does not apply -> the server silently clears what the
--     employee just chose, and they watch their answer disappear;
--   fail to offer it where it does   -> the server refuses the save with
--     BILLABLE_REQUIRED and there is no field on screen to fix.
--
-- WHY A SEPARATE FUNCTION RATHER THAN A COLUMN ON my_timesheet_projects
--   That function's OUT columns cannot be changed by CREATE OR REPLACE; 787 had
--   to DROP and rebuild it, wrapper included, to add one. Its shape is also
--   about WHICH projects you may pick, and billability is not that question.
--   A separate two-line reader stays out of the way of both.
--
-- WHAT IT DISCLOSES
--   Which projects are billable, to someone who can already see the project
--   list. That is a commercial classification, not a rate or a value, and the
--   employee booking to the project is being asked to reason about it anyway.
--   No dates, no amounts, no per-project figures.
--
-- NOT AN ENFORCEMENT POINT
--   Offers only, exactly like my_timesheet_projects. The rule that decides what
--   is stored lives in save_timesheet_entry and bulk_create_timesheet_entries
--   (821) and is not weakened by anything a caller does with this list.
--
-- Depends on : 001 (picklist_values.ref_id, projects.project_type_id), 821
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.billable_project_ids()
RETURNS TABLE (id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT p.id
  FROM   projects p
  JOIN   picklist_values pv ON pv.id = p.project_type_id
  WHERE  pv.ref_id = 'P001'
$fn$;

REVOKE ALL ON FUNCTION public.billable_project_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.billable_project_ids() TO authenticated;

COMMENT ON FUNCTION public.billable_project_ids() IS
  'Mig 823: the ids of projects whose type is P001 (billable). So the timesheet '
  'screen knows when to offer the per-activity billable choice. Offers only -- '
  'what is actually stored is decided by save_timesheet_entry and '
  'bulk_create_timesheet_entries (mig 821), whatever a caller believes.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  n     integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
                 WHERE n2.nspname = 'public' AND p.proname = 'billable_project_ids') THEN
    RAISE EXCEPTION 'MIG 823 FAILED: billable_project_ids not created.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'billable_project_ids';

  -- It answers exactly one question. Anything else here would be a second
  -- place for the billable rule to live, and two places disagree eventually.
  IF position('P001' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 823 FAILED: the function does not test for P001.';
  END IF;
  IF position('hours_minutes' IN v_src) > 0 OR position('timesheet' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 823 FAILED: the function reads timesheet data. It answers a question about projects.';
  END IF;

  -- authenticated may call it; PUBLIC may not.
  SELECT count(*) INTO n
  FROM   information_schema.routine_privileges
  WHERE  routine_schema = 'public' AND routine_name = 'billable_project_ids'
    AND  grantee = 'authenticated' AND privilege_type = 'EXECUTE';
  IF n < 1 THEN
    RAISE EXCEPTION 'MIG 823 FAILED: authenticated cannot execute it.';
  END IF;

  RAISE NOTICE 'Migration 823 verified: billable_project_ids reads project types only, and is executable by authenticated.';
END $mig$;

COMMIT;
