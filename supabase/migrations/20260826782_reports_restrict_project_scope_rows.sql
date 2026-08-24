-- =============================================================================
-- Migration 782: reports show a project lead their project, and only that
--
-- PIECE 3 of 3 (see docs/project-manager-persona-design.md, especially §3.3a)
--
-- THE LEAK THIS CLOSES
-- ════════════════════
-- Migration 781 put current project members into the lead's target population.
-- That is right for the timesheet screen -- Hari should be able to open Meera's
-- timesheet while she is on his project.
--
-- It is WRONG for the reports. The reports build their row set from that same
-- population, so the moment Meera enters it Hari sees every hour she has ever
-- booked, including the 100 hours on a project he has nothing to do with. That
-- is the precise outcome this whole design exists to prevent, arriving through
-- the back door.
--
-- THE FIX -- two disjoint row sets
-- ────────────────────────────────
--   Set A (unrestricted)      rows of employees the caller reaches through a
--                             scope type OTHER than project_members. All their
--                             rows, exactly as today. Nobody's report changes.
--
--   Set B (project-restricted) every remaining row booked to a project the
--                             caller manages. No membership test. No dates.
--
-- Set B already exists -- migrations 770 and 771 built it as `hdr_pm`. What was
-- missing is set A's exclusion, without which set B never gets the chance.
--
-- WHY SET B HAS NO DATES
-- ──────────────────────
-- "Was Meera a member in March" answers differently in April than in July, so
-- the same March total drifts. "Was this hour booked to my project" has one
-- true answer forever. The report asks the second question. §3.3a.
--
-- CHANGES
-- ───────
--   1. get_target_population_scoped(module, action, exclude_scope_types[])
--      -- the real body, lifted from the live 2-arg function
--      get_target_population(module, action) becomes a thin wrapper over it
--   2. time_report_scope_mode() / _ids()  -- exclude project_members => set A
--   3. time_report_project_member_ids()   -- NEW, for un-redaction
--   4. time_report_managed_project_ids()  -- gate widened to the new scope
--   5. timesheet_report_utilisation()     -- redact only genuine outsiders
--
-- NOT CHANGED
-- ───────────
--   user_can()                    -- the timesheet screen keeps the full scope
--   timesheet_report_project_summary  -- aggregates by project, shows no
--                                        employee attributes, nothing to redact
--   Set A's behaviour for every existing caller
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Split get_target_population into a body and a wrapper
-- ═══════════════════════════════════════════════════════════════════════════
-- The reports need "the population, but pretend this scope type isn't there".
-- Two ways to get it: copy the function and maintain two bodies, or move the
-- body somewhere it can take a parameter and leave a wrapper behind. Copying
-- is how functions drift -- migrations 734/736/737 are the local proof -- so
-- the body moves.
--
-- LOUD NOTE FOR WHOEVER PATCHES THIS NEXT
-- ───────────────────────────────────────
-- After this migration, get_target_population(text,text) is THREE LINES. If you
-- are anchoring a substitution against its body, you want
-- get_target_population_scoped(text,text,text[]) instead. An anchored patch
-- aimed at the old body will fail its hit-count assertion rather than silently
-- do nothing, which is the intended behaviour.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_sig text := 'FUNCTION public.get_target_population(p_module text, p_action text)';
  r_sig text := 'FUNCTION public.get_target_population_scoped(p_module text, p_action text, p_exclude_scope_types text[] DEFAULT NULL)';

  -- The one place the caller's target groups are gathered.
  a_flt text := E'      AND  tg.scope_type <> ''everyone''\n  ),';
  r_flt text := E'      AND  tg.scope_type <> ''everyone''\n'
             || E'      AND  (p_exclude_scope_types IS NULL\n'
             || E'            OR NOT (tg.scope_type = ANY (p_exclude_scope_types)))\n  ),';
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_target_population_scoped'
  ) THEN
    RAISE NOTICE 'mig 782: get_target_population_scoped already exists -- skipping split';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'get_target_population'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_module text, p_action text';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 782: get_target_population(text,text) not found';
  END IF;

  -- Mig 781 must already have landed, or the scoped copy would be missing the
  -- very branch this migration exists to exclude.
  IF position('project_members' in v_src) = 0 THEN
    RAISE EXCEPTION
      'mig 782: get_target_population has no project_members branch -- mig 781 has not been applied';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_sig, ''))) / NULLIF(length(a_sig), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 782: signature anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a_sig, r_sig);

  v_hits := (length(v_new) - length(replace(v_new, a_flt, ''))) / NULLIF(length(a_flt), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 782: scope filter anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_flt, r_flt);

  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION get_target_population_scoped(text, text, text[]) IS
  'Mig 782: the real body of get_target_population, plus an exclusion list. '
  'p_exclude_scope_types drops matching target groups before resolution, so a '
  'caller can ask "the population, ignoring this scope type". The reports use '
  'it to exclude project_members -- see mig 782 header and design doc §3.3a. '
  'PATCH THIS, not the two-argument wrapper.';

GRANT EXECUTE ON FUNCTION get_target_population_scoped(text, text, text[]) TO authenticated;


CREATE OR REPLACE FUNCTION public.get_target_population(p_module text, p_action text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT public.get_target_population_scoped(p_module, p_action, NULL);
$fn$;

COMMENT ON FUNCTION get_target_population(text, text) IS
  'Wrapper over get_target_population_scoped(module, action, NULL) since mig 782. '
  'Behaviour is unchanged for every existing caller. The body lives in the '
  'scoped function -- patch that one.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Set A — the report scope, with project_members held back
-- ═══════════════════════════════════════════════════════════════════════════
-- Held back rather than subtracted, and the difference matters. Someone who is
-- BOTH a department head and a project lead reaches their department through
-- same_department and their project's outsiders through project_members. A
-- subtraction would strip their own department members out of set A and clip
-- them to the project. Excluding the scope type at resolution time leaves the
-- other routes intact, so they get their department in full plus the project's
-- outsiders -- which is the right answer, and falls out for free.

CREATE OR REPLACE FUNCTION public.time_report_scope_mode()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pop jsonb;
BEGIN
  IF is_super_admin() THEN
    RETURN 'all';
  END IF;

  v_pop := get_target_population_scoped('timesheet', 'view', ARRAY['project_members']);

  IF v_pop->>'mode' = 'all'    THEN RETURN 'all';    END IF;
  IF v_pop->>'mode' = 'scoped' THEN RETURN 'scoped'; END IF;
  RETURN 'none';
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_scope_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_scope_mode() TO authenticated;

COMMENT ON FUNCTION public.time_report_scope_mode() IS
  'all | scoped | none. Check this BEFORE calling time_report_scope_ids() -- that '
  'function is empty for both all and none, and the two mean opposite things. '
  'Since mig 782 this is SET A: project_members is excluded, because people '
  'reached only through a project must be clipped to that project rather than '
  'followed to their other work. A caller whose only grant is project_members '
  'gets ''none'' here and is served entirely by the managed-projects branch.';


CREATE OR REPLACE FUNCTION public.time_report_scope_ids()
RETURNS TABLE (employee_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pop jsonb;
BEGIN
  IF is_super_admin() THEN
    RETURN;
  END IF;

  v_pop := get_target_population_scoped('timesheet', 'view', ARRAY['project_members']);

  IF v_pop->>'mode' <> 'scoped' THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT (jsonb_array_elements_text(v_pop->'ids'))::uuid;
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_scope_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_scope_ids() TO authenticated;

COMMENT ON FUNCTION public.time_report_scope_ids() IS
  'Set A ids. Must agree with time_report_scope_mode() -- both exclude '
  'project_members since mig 782.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Who is genuinely an outsider
-- ═══════════════════════════════════════════════════════════════════════════
-- Set B carries two different kinds of person and they deserve different
-- treatment:
--
--   a current member of my project   -- I am entitled to them, mig 781 says so.
--                                       Show the name and the department.
--   anyone else who booked to it     -- an ex-member, a correction, someone
--                                       staffed before project_members existed.
--                                       I get their hours because they are my
--                                       project's cost. I do not get the person.
--
-- So the redaction stops being blanket and starts meaning something:
-- "you are seeing this line because it is your project, not because this is
-- your person."

CREATE OR REPLACE FUNCTION public.time_report_project_member_ids()
RETURNS TABLE (employee_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  IF NOT time_report_is_project_manager() THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT DISTINCT pm.employee_id
    FROM   project_members pm
    JOIN   projects  pr ON pr.id = pm.project_id
    JOIN   employees e  ON e.id  = pm.employee_id
    WHERE  pr.manager_id     = v_me
      AND  pr.active         = true
      AND  e.deleted_at      IS NULL
      AND  pm.effective_from <= CURRENT_DATE
      AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE);
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_project_member_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_project_member_ids() TO authenticated;

COMMENT ON FUNCTION public.time_report_project_member_ids() IS
  'Mig 782: current members of projects this caller manages. Drives redaction '
  'only -- it never widens which rows appear. Empty for anyone the '
  'managed-projects branch does not apply to.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Set B's gate accepts the new scope
-- ═══════════════════════════════════════════════════════════════════════════
-- Before this, the branch turned on only for holders of timesheet.view_project
-- (the `Managed projects` tick). A lead set up the new way -- Project Manager
-- role, Project Members target group -- would have had an empty set A and a
-- closed set B, and seen nothing at all.
--
-- Both routes are honoured. The old tick is deliberately left working; the
-- design says retire it only once the new path is proven on real data.

CREATE OR REPLACE FUNCTION public.time_report_has_project_scope()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles                 ur
    JOIN   permission_set_assignments psa ON psa.role_id           = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    JOIN   target_groups              tg  ON tg.id                 = psa.target_group_id
    WHERE  ur.profile_id = auth.uid()
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code        = 'timesheet'
      AND  p.action      = 'view'
      AND  tg.scope_type = 'project_members'
  );
$fn$;

REVOKE ALL ON FUNCTION public.time_report_has_project_scope() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_has_project_scope() TO authenticated;

COMMENT ON FUNCTION public.time_report_has_project_scope() IS
  'Mig 782: does this caller hold Timesheet -> View with the Project Members '
  'target group. The new route into the managed-projects branch.';


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
  -- Gate first, both routes. Without one of them this returns nothing whatever
  -- the projects table says, so a manager_id set for reporting purposes never
  -- silently becomes an access grant.
  IF NOT (user_can('timesheet', 'view_project', NULL)
          OR time_report_has_project_scope()) THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN
    RETURN;                      -- no employee behind this login
  END IF;

  RETURN QUERY
    SELECT p.id
    FROM   projects p
    WHERE  p.manager_id = v_me
      AND  p.active     = true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.time_report_managed_project_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.time_report_managed_project_ids() TO authenticated;

COMMENT ON FUNCTION public.time_report_managed_project_ids() IS
  'Projects where the caller is the Reporting Manager, gated on either '
  'timesheet.view_project (the Managed projects tick, mig 767) or a '
  'Project Members target group on Timesheet -> View (mig 781). '
  'Restricted to active projects since mig 782.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Utilisation: redact the outsiders, not the team
-- ═══════════════════════════════════════════════════════════════════════════
-- One expression. `via_project` stops being a constant on the managed-projects
-- branch and starts meaning what its name says: this row reached me through the
-- project rather than through the person. For a current member it is now false,
-- so the name, the department and the absence of a badge all follow.
--
-- The subquery is uncorrelated, so the planner hashes it once per statement
-- rather than per row.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'           true AS via_project\n'
          || E'    FROM   timesheet_entries e\n'
          || E'    JOIN   hdr_pm h';

  r1 text := E'           NOT (h.employee_id IN\n'
          || E'                (SELECT employee_id FROM time_report_project_member_ids()))\n'
          || E'             AS via_project\n'
          || E'    FROM   timesheet_entries e\n'
          || E'    JOIN   hdr_pm h';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 782: timesheet_report_utilisation not found';
  END IF;

  IF position('time_report_project_member_ids' in v_src) > 0 THEN
    RAISE NOTICE 'mig 782: utilisation already un-redacts current members -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION
      'mig 782: utilisation via_project anchor matched % times, expected 1 -- '
      'mig 771 may not be applied, or the function has been rewritten', v_hits;
  END IF;

  v_new := replace(v_src, a1, r1);
  EXECUTE v_new;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_ok boolean;
BEGIN
  -- The wrapper must still answer for its old callers.
  IF get_target_population('timesheet', 'view') IS NULL THEN
    RAISE EXCEPTION 'mig 782: get_target_population wrapper returned NULL';
  END IF;

  -- Set A must not be able to see project_members, ever.
  SELECT position('project_members' in pg_get_functiondef(p.oid)) > 0 INTO v_ok
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_report_scope_mode';
  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'mig 782: time_report_scope_mode does not exclude project_members';
  END IF;

  SELECT position('project_members' in pg_get_functiondef(p.oid)) > 0 INTO v_ok
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'time_report_scope_ids';
  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'mig 782: time_report_scope_ids does not exclude project_members';
  END IF;

  -- And the exclusion must actually bite: a population computed with
  -- project_members excluded can never be larger than one computed without.
  IF jsonb_array_length(COALESCE(
        get_target_population_scoped('timesheet','view', ARRAY['project_members'])->'ids',
        '[]'::jsonb))
     > jsonb_array_length(COALESCE(
        get_target_population_scoped('timesheet','view', NULL)->'ids',
        '[]'::jsonb))
  THEN
    RAISE EXCEPTION 'mig 782: excluding a scope type grew the population';
  END IF;

  RAISE NOTICE 'mig 782: OK -- set A excludes project_members, set B gate widened';
END $mig$;
