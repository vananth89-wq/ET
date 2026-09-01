-- =============================================================================
-- Migration 830 — who is on the project you are helping
--
-- WHAT NEEDS IT
-- ═════════════
-- 829 made a support entry name who asked for the help. The screen now has to
-- offer that choice, and nothing in the database can answer the question it is
-- asking: `my_timesheet_projects` returns YOUR memberships, and there is no
-- reader at all for "who is on THAT project".
--
-- The list is deliberately the helped project's team on the DAY the hours were
-- worked. A requester who was not on the project is a strange claim, and a
-- picker of every employee in the company makes the field a formality -- 200
-- names, any of which can be chosen as easily as the right one, which is the
-- state 829 exists to end.
--
-- MEMBERSHIP IS PER DATE, NOT A BOOLEAN
--   `project_members` carries effective_from / effective_to, so somebody can be
--   on AZAD in August and off it in October. This takes a date and answers for
--   that date. It matters most for editing: reopening an August entry must show
--   August's team, and a requester who has since left must still be nameable --
--   which the caller gets by keeping the stored id, exactly as the project
--   picker does (the value already held is always an option).
--
-- WHAT IT DISCLOSES, STATED PLAINLY
--   The names of the people on a project, to an employee who is not on it.
--   That is a step past `bookable_projects_all` (801), which discloses project
--   NAMES to everyone -- this discloses who works on them. In a firm this size
--   that is ordinary colleague information and the employee needs it to name
--   the person who asked them for help. It returns names and employee codes and
--   nothing else: no rates, no allocation percentages, no dates, no contact
--   details. If that judgement is ever wrong, this function is the single place
--   it changes, in the same way bookable_projects_all is for project names.
--
-- NOT AN ENFORCEMENT POINT
--   Offers only, like every other picker reader here. Rule (i) (829) requires a
--   requester; it does not require the requester to be on the project, because
--   a bid lead or a manager outside the team can legitimately be the person who
--   asked. The picker narrows; the rule does not.
--
-- Depends on : 786/787 (project_members and its effective dating), 829
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.project_team_on(
  p_project_id uuid,
  p_on_date    date
)
RETURNS TABLE (
  employee_id   uuid,
  name          text,
  employee_code text,
  is_lead       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT DISTINCT ON (e.id)
         e.id,
         e.name,
         e.employee_id,
         -- The project's own manager, surfaced so the employee can find the
         -- likely asker without knowing the team. Not a separate query: the
         -- lead is a member like any other and is simply marked.
         (p.manager_id IS NOT DISTINCT FROM e.id) AS is_lead
  FROM   project_members pm
  JOIN   employees e ON e.id = pm.employee_id
  JOIN   projects  p ON p.id = pm.project_id
  WHERE  pm.project_id      = p_project_id
    AND  p_project_id      IS NOT NULL
    AND  p_on_date         IS NOT NULL
    -- The stint covers the day the hours were worked, not today. Editing an
    -- August entry in October must show August's team.
    AND  pm.effective_from <= p_on_date
    AND  (pm.effective_to IS NULL OR pm.effective_to >= p_on_date)
  -- DISTINCT ON because a person can hold two overlapping stints on one
  -- project -- rejoining after a gap, or an allocation edited into two rows.
  -- Without it they appear twice in the picker and the employee cannot tell
  -- which one to choose, because there is no difference to see.
  ORDER  BY e.id, pm.effective_from DESC
$fn$;

REVOKE ALL ON FUNCTION public.project_team_on(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_team_on(uuid, date) TO authenticated;

COMMENT ON FUNCTION public.project_team_on(uuid, date) IS
  'Mig 830: the people on a project on a given date, with its manager marked. '
  'So the timesheet can offer who asked for help (829). Names and employee '
  'codes only. Offers only -- rule (i) requires a requester but does not '
  'require them to be on the project, because a lead outside the team can '
  'legitimately be the person who asked.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  v_res text;
  n     integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'project_team_on';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 830 FAILED: project_team_on was not created.';
  END IF;

  -- It answers about people on a project. Anything reading hours here would be
  -- a second, unaudited way to see somebody's timesheet.
  IF position('timesheet' IN v_src) > 0 OR position('hours_minutes' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: the function reads timesheet data. It answers a question about project membership.';
  END IF;

  -- Date-scoped, not "is a member now". Without the effective_to test, an
  -- August entry reopened in October would offer October's team.
  IF position('pm.effective_from <= p_on_date' IN v_src) = 0
     OR position('pm.effective_to IS NULL OR pm.effective_to >= p_on_date' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: membership is not tested against the given date.';
  END IF;

  -- One row per person, whatever their stint history.
  IF position('DISTINCT ON (e.id)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: a person with two overlapping stints would appear twice, identically, in the picker.';
  END IF;

  SELECT count(*) INTO n
  FROM   information_schema.routine_privileges
  WHERE  routine_schema = 'public' AND routine_name = 'project_team_on'
    AND  grantee = 'authenticated' AND privilege_type = 'EXECUTE';
  IF n < 1 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: authenticated cannot execute it, so the picker would always be empty.';
  END IF;

  -- And it returns nothing it was not asked for. A picker needs a name and a
  -- code; anything else is disclosure nobody signed off.
  --
  -- Tested against the RESULT SIGNATURE, not the source text. The first version
  -- of this searched the whole function body and failed on the word
  -- "allocation" in a comment explaining why DISTINCT ON is there -- an
  -- assertion about prose, when what it meant was an assertion about the
  -- interface. Only the signature can actually disclose anything.
  SELECT pg_get_function_result(p.oid) INTO v_res
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'project_team_on';

  IF v_res IS NULL THEN
    RAISE EXCEPTION 'MIG 830 FAILED: no result signature.';
  END IF;
  IF position('employee_id' IN v_res) = 0
     OR position('name' IN v_res) = 0
     OR position('employee_code' IN v_res) = 0
     OR position('is_lead' IN v_res) = 0 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: the result signature is not the four columns the picker needs: %', v_res;
  END IF;

  SELECT count(*) INTO n
  FROM   regexp_matches(lower(v_res), '(rate|cost|salary|allocation|percent|email|phone)', 'g');
  IF n > 0 THEN
    RAISE EXCEPTION 'MIG 830 FAILED: the result signature discloses more than a name and a code: %', v_res;
  END IF;

  RAISE NOTICE 'Migration 830 verified: project_team_on answers membership for a given DATE, one row per person, names and codes only.';
END $mig$;

COMMIT;
