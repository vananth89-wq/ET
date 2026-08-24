-- =============================================================================
-- Migration 784: one rule for "which projects count" -- the active ones
--
-- THE INCONSISTENCY
-- ═════════════════
-- Everything built in 780-783 asks the same question, and until now two of them
-- answered it differently:
--
--   mig 780  project_manager role sync     projects.active = true
--   mig 781  Project Members scope type    projects.active = true
--   mig 782  time_report_managed_project_ids  projects.active = true
--   mig 773  my_staffable_projects()       ← no filter
--   mig 783  my_staffable_projects_detail()← no filter
--
-- So deactivating a project took the lead's role, their target-group scope and
-- their report branch away, but left the project sitting on My Projects, still
-- staffable. The screen and the role disagreed about what the lead manages,
-- which is the kind of split that eventually produces a bug report nobody can
-- reproduce because it depends on which surface you looked at.
--
-- THE RULE, STATED ONCE
-- ─────────────────────
--   A project you are Reporting Manager on counts while it is ACTIVE.
--   Deactivate it and every derived thing goes at the same moment: the role,
--   the scope, the report branch, the screen, and the ability to edit its
--   membership.
--
-- WHAT STAYS OPEN ON A CLOSED PROJECT
-- ───────────────────────────────────
-- The ADMIN doors, deliberately. can_staff_project() returns true for a super
-- admin and for anyone holding projects_mgmt.edit before it ever consults
-- my_staffable_projects(), so somebody correcting the history of a closed
-- project is not blocked -- only the lead's automatic door closes. That is the
-- right split: a closed project should not be routine work for its lead, and
-- should still be fixable by an administrator.
--
-- Employees also keep reading their OWN membership rows: the select policy has
-- a separate `employee_id = get_my_employee_id()` arm that this does not touch.
--
-- CHANGES
-- ───────
--   1. my_staffable_projects()         -- add the filter. Fixes, in one edit,
--                                         can_staff_project(), my_project_members(),
--                                         project_member_add/_remove and the
--                                         three project_members RLS policies,
--                                         all of which delegate to it.
--   2. my_staffable_projects_detail()  -- the same filter, for the screen.
--
-- Both are CREATE OR REPLACE with an unchanged signature, so the four policies
-- naming my_staffable_projects() are never dropped or rebuilt.
-- =============================================================================

SET jit = 'off';


-- ─────────────────────────────────────────────────────────────────────────────
-- Patch both in place
-- ─────────────────────────────────────────────────────────────────────────────
-- Anchored rather than retyped. my_staffable_projects() is from mig 773 and
-- my_staffable_projects_detail() from 783, but "the last file that defines it"
-- is not a promise about what is running -- and this one sits behind three RLS
-- policies, so a stale body pasted over it would be a security change made by
-- accident.

DO $mig$
DECLARE
  v_fn   text;
  v_src  text;
  v_new  text;
  v_hits int;

  a1 text := E'    WHERE  p.manager_id = v_me\n';
  r1 text := E'    WHERE  p.manager_id = v_me\n'
          || E'      AND  p.active     = true\n';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['my_staffable_projects', 'my_staffable_projects_detail'] LOOP

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'mig 784: %() not found -- refusing to guess at its shape', v_fn;
    END IF;

    IF position('p.active' in v_src) > 0 THEN
      RAISE NOTICE 'mig 784: %() already filters on active -- skipping', v_fn;
      CONTINUE;
    END IF;

    v_hits := (length(v_src) - length(replace(v_src, a1, ''))) / NULLIF(length(a1), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 784: %() manager_id anchor matched % times, expected 1', v_fn, v_hits;
    END IF;

    v_new := replace(v_src, a1, r1);
    EXECUTE v_new;
    RAISE NOTICE 'mig 784: %() now filters on active', v_fn;
  END LOOP;
END $mig$;

COMMENT ON FUNCTION public.my_staffable_projects() IS
  'Active projects where the caller is the Reporting Manager, gated on '
  'projects_mgmt.manage_members. The lead door for can_staff_project(), '
  'my_project_members(), project_member_add/_remove and the three '
  'project_members RLS policies -- all of which delegate here. '
  'Restricted to active projects in mig 784, matching the role sync (780), '
  'the Project Members scope (781) and the report branch (782).';

COMMENT ON FUNCTION public.my_staffable_projects_detail() IS
  'my_staffable_projects() plus the fields the My Projects screen displays -- '
  'type, dates, budget and hours booked, current and past member counts. Same '
  'gate, same rows, active only since mig 784. Kept separate because '
  'my_staffable_projects() is named in RLS policies and must not change shape.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['my_staffable_projects', 'my_staffable_projects_detail'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
        AND pg_get_functiondef(p.oid) LIKE '%p.active%'
    ) THEN
      RAISE EXCEPTION 'mig 784: %() does not filter on active after the patch', v_fn;
    END IF;
  END LOOP;

  -- The shape RLS depends on must be untouched.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_staffable_projects'
      AND pg_get_function_result(p.oid) LIKE '%member_count%'
  ) THEN
    RAISE EXCEPTION 'mig 784: my_staffable_projects() lost its shape -- RLS depends on it';
  END IF;

  -- The admin door must NOT have been narrowed.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'can_staff_project'
      AND pg_get_functiondef(p.oid) LIKE '%projects_mgmt%edit%'
  ) THEN
    RAISE EXCEPTION 'mig 784: can_staff_project lost its admin door';
  END IF;

  RAISE NOTICE 'mig 784: OK -- staffing follows active projects, admin door intact';
END $mig$;
