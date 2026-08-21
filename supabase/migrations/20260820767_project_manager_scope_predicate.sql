-- =============================================================================
-- Migration : 20260820767_project_manager_scope_predicate.sql
-- Purpose   : The Project Manager persona's scope, as a predicate. Design doc s5.
--
-- THE PROBLEM  Every persona in the RBP engine is scoped by EMPLOYEE:
--   get_target_population('timesheet','view') returns employee ids and
--   time_report_scope_ids() filters on them. A Project Manager is not shaped
--   that way. A PM needs the hours logged against THEIR PROJECT, by people who
--   may sit in departments they have no right to see individually. No
--   composition of employee ids expresses that.
--
-- THIS MIGRATION ADDS THE PREDICATE AND NOTHING ELSE.
--   No report reads it yet. That is deliberate: a scope predicate and the
--   queries that trust it are the two halves of a security change, and landing
--   them in one migration means the first time anyone sees the new rows is also
--   the first time the predicate has ever run. Here it can be granted, called
--   and inspected on Dev while every report still behaves exactly as it does
--   today.
--
-- IT FAILS CLOSED AT FOUR SEPARATE POINTS
--   no timesheet.view_project grant      -> empty
--   caller has no profile/employee link  -> empty  (get_my_employee_id() NULL)
--   caller manages no projects           -> empty
--   project.manager_id NULL              -> never matches
--   An empty result means the caller gains nothing anywhere, which is the state
--   every reader must treat as "behave exactly as before".
--
-- WHY manager_id AND NOT A MEMBERSHIP TABLE  Mig 754: RLS needs one question
--   answered -- "is this caller the manager of this project" -- and one manager
--   per project answers it. A project_members table remains additive.
--
-- SUPER ADMIN IS NOT SPECIAL-CASED HERE.  is_super_admin() already returns
--   'all' from the employee scope, so a super admin sees everything through the
--   normal path. Returning every project id for them as well would make the PM
--   branch light up for a user who does not need it, and the branch is one that
--   changes query plans -- see 768.
--
-- Depends on : 754 (projects.manager_id), 20260419002 (get_my_employee_id),
--              732 (the permissions_action_check mechanism)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0  Widen permissions_action_check FIRST
--
-- Same mechanism as 732, 745 and 766. 745 failed on Dev with SQLSTATE 23514 by
-- forgetting it; the canonical list plus whatever the column already holds
-- keeps a replay from adjudicating values this migration did not create.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_canonical text[] := ARRAY['view','create','edit','delete','history','lookup',
                              'view_all_pending','edit_all_pending',
                              'bulk_import','bulk_export',
                              'view_inactive','reassign','approve',
                              'view_compliance','view_utilisation','view_projects',
                              'view_project',
                              'view_capacity','view_analytics'];
  v_extra     text[];
  v_allowed   text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[])
    INTO v_extra
  FROM   public.permissions
  WHERE  action IS NOT NULL AND action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 767: permissions.action holds % value(s) outside the canonical set: %.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;

  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format(
    'ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
    'CHECK (action = ANY (%L::text[]))', v_allowed);

  RAISE NOTICE 'MIG 767: permissions_action_check now admits % value(s).',
               array_length(v_allowed, 1);
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  The permission
--
-- On `timesheet`, not on `timesheet_reports`. It does not open a report -- it
-- widens WHICH ROWS the reports already granted to you may return, which is the
-- same kind of thing the Timesheet view target population does. An
-- administrator looking for "who can see whose timesheet data" should find both
-- answers in one place.
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'timesheet.view_project',
       'View Timesheets For Managed Projects',
       'See timesheet entries recorded against projects where this person is '
       'the reporting manager -- including entries by employees outside their '
       'target population. Department, planned hours and other HR columns stay '
       'hidden on those rows. Grants nothing on its own: the person still needs '
       'the relevant report permission to open a report at all.',
       'view_project',
       90
FROM   public.modules m
WHERE  m.code = 'timesheet'
ON CONFLICT (code) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  The predicate
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.time_report_managed_project_ids()
RETURNS TABLE (project_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  -- Gate first. Without the grant this returns nothing whatever the projects
  -- table says, so a manager_id set for reporting purposes never silently
  -- becomes an access grant.
  IF NOT user_can('timesheet', 'view_project', NULL) THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN
    RETURN;                      -- no employee behind this login
  END IF;

  RETURN QUERY
    SELECT p.id FROM projects p WHERE p.manager_id = v_me;
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_managed_project_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_managed_project_ids() TO authenticated;

COMMENT ON FUNCTION public.time_report_managed_project_ids() IS
  'Mig 767: the projects this caller manages, as rows, for a semi-join. Empty '
  'unless timesheet.view_project is granted AND the caller is an employee AND '
  'that employee is the reporting manager of at least one project. Empty means '
  'the reports must behave exactly as they did before the PM path existed.';

/**
 * Cheap "is the PM branch live for this caller" test.
 *
 * The reports use it to skip the whole branch, so a caller who manages nothing
 * -- almost everyone -- runs the identical query they ran before this feature.
 */
CREATE OR REPLACE FUNCTION public.time_report_is_project_manager()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT EXISTS (SELECT 1 FROM time_report_managed_project_ids());
$fn$;

REVOKE ALL ON FUNCTION public.time_report_is_project_manager() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_is_project_manager() TO authenticated;

COMMENT ON FUNCTION public.time_report_is_project_manager() IS
  'Mig 767: whether the PM branch applies to this caller at all. False for '
  'everyone without the grant, which is what lets the reports keep their '
  'existing query plan for the overwhelming majority of runs.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code = 'timesheet.view_project') THEN
    v_missing := v_missing || 'the timesheet.view_project permission was not seeded'::text; END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_report_managed_project_ids';

  IF v_src IS NULL THEN
    v_missing := v_missing || 'the predicate was not created'::text;
  ELSE
    IF position('''timesheet'', ''view_project''' IN v_src) = 0 THEN
      v_missing := v_missing || 'the predicate does not check the grant -- manager_id would become an access grant on its own'::text; END IF;
    IF position('get_my_employee_id()' IN v_src) = 0 THEN
      v_missing := v_missing || 'the predicate does not resolve the caller to an employee'::text; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'time_report_is_project_manager') THEN
    v_missing := v_missing || 'the branch test was not created'::text; END IF;

  -- NOTHING may read it yet. If a report already references the predicate then
  -- this migration is not the inert half it claims to be, and the review that
  -- assumed it was is wrong.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('timesheet_report_utilisation','timesheet_report_compliance',
                        'timesheet_report_project_summary')
      AND pg_get_functiondef(p.oid) LIKE '%time_report_managed_project_ids%'
  ) THEN
    v_missing := v_missing || 'a report already reads the predicate -- 767 is meant to change no behaviour'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 767 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 767 verified: the PM predicate exists, fails closed, and no report reads it yet.';
END $mig$;

COMMIT;
