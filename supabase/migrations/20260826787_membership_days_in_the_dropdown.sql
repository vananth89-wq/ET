-- =============================================================================
-- Migration 787: the dropdown learns which DAYS you were on the project
--
-- THE ASYMMETRY THIS CLOSES
-- ═════════════════════════
-- Two windows govern whether a project may be chosen for a date, and until now
-- they were enforced at different resolutions:
--
--   projects.start_date / end_date        frontend, PER DAY
--     -> projectActiveOn() in MyTimesheet: every date being entered must fall
--        inside the project's validity window.
--
--   project_members.effective_from / to   database, PER MONTH
--     -> my_timesheet_projects() offers a project when the stint OVERLAPS the
--        period at all.
--
-- So a stint ending 10 March overlaps March, the project is offered for all of
-- March, and nothing stops an entry on 25 March. The project's own window would
-- have caught that date; the person's allocation window could not, because the
-- screen never knew where inside the month the stint ended.
--
-- THE FIX
-- ───────
-- Return the stints themselves, not just a boolean. member_spells is a jsonb
-- array of {from, to} for every stint overlapping the period -- an array, not a
-- single pair, because somebody can be on a project 1-10 Jan and again 20-31
-- Jan, and min/max across those two would silently hand back the ten days in
-- the middle when they were off it.
--
-- THE ESCAPE HATCH, KEPT ON PURPOSE
-- ─────────────────────────────────
-- The screen must NOT apply the day rule to a project the person has already
-- booked to (has_entries). An entry that exists has to be able to name its own
-- project: filter it out of the list and editing that entry finds its project
-- missing from the select, which is the "old timesheet loses its project"
-- failure the booked arm exists to prevent.
--
-- The consequence, stated plainly rather than buried: this closes the gap for
-- somebody who has NOT booked to the project before. An ex-member who has
-- booked to it keeps being offered it on any date. That is caveat (2) -- the
-- date-blind booked arm -- and it does not get fixed by a nicer dropdown. It
-- needs enforcement in the database, with an exemption for entries that already
-- exist, and that is still a switch nobody has thrown.
--
-- CHANGES
-- ───────
--   my_timesheet_projects(uuid, date, date)  -- + member_spells jsonb
--   my_timesheet_projects(uuid)              -- wrapper rebuilt to match
--
-- Both are DROPped first: the OUT columns change, and CREATE OR REPLACE cannot
-- do that. The wrapper's body is a quoted string, so Postgres does not track it
-- as a dependency -- it would survive the drop and fail at call time instead.
-- Rebuilt here in the same migration for that reason.
-- =============================================================================

SET jit = 'off';

DROP FUNCTION IF EXISTS public.my_timesheet_projects(uuid, date, date);
DROP FUNCTION IF EXISTS public.my_timesheet_projects(uuid);

CREATE FUNCTION public.my_timesheet_projects(
  p_employee_id  uuid,
  p_period_start date,
  p_period_end   date
)
RETURNS TABLE (
  id            uuid,
  name          text,
  active        boolean,
  start_date    date,
  end_date      date,
  is_member     boolean,
  has_entries   boolean,
  member_spells jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  IF p_employee_id IS NULL OR p_period_start IS NULL OR p_period_end IS NULL THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();

  -- Your own sheet, or one you are entitled to see. SECURITY DEFINER means the
  -- gate has to be explicit -- there is no RLS behind this to catch a mistake.
  --
  -- IS NOT DISTINCT FROM, not `=`. For a login with no employee behind it v_me
  -- is NULL, `p_employee_id = v_me` is NULL, and NULL OR false is NULL, so
  -- `IF NOT (...)` is NULL -- which plpgsql treats as false and falls straight
  -- through the gate. (Caught by test T8 on mig 783.)
  IF NOT (is_super_admin()
          OR p_employee_id IS NOT DISTINCT FROM v_me
          OR COALESCE(user_can('timesheet', 'view', p_employee_id), false)
          OR COALESCE(user_can('timesheet', 'edit', p_employee_id), false)) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH mem AS (
    -- Overlaps the period at all. Somebody who joined mid-month was on the
    -- project that month, and their timesheet for it must offer it. WHICH days
    -- inside the month is what member_spells then answers.
    SELECT pm.project_id, pm.effective_from, pm.effective_to
    FROM   project_members pm
    WHERE  pm.employee_id    = p_employee_id
      AND  pm.effective_from <= p_period_end
      AND  (pm.effective_to IS NULL OR pm.effective_to >= p_period_start)
  ),
  booked AS (
    -- Deliberately date-blind, and deliberately not limited to this period:
    -- an entry that exists must always be able to name its own project, or
    -- editing an old timesheet would silently lose it.
    SELECT DISTINCT e.project_id
    FROM   timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  h.employee_id  = p_employee_id
      AND  e.project_id   IS NOT NULL
  ),
  keep AS (
    SELECT project_id FROM mem
    UNION
    SELECT project_id FROM booked
  )
  SELECT p.id, p.name, p.active, p.start_date, p.end_date,
         EXISTS (SELECT 1 FROM mem    m WHERE m.project_id = p.id),
         EXISTS (SELECT 1 FROM booked b WHERE b.project_id = p.id),
         (SELECT jsonb_agg(jsonb_build_object('from', m.effective_from, 'to', m.effective_to)
                           ORDER BY m.effective_from)
          FROM   mem m WHERE m.project_id = p.id)
  FROM   projects p
  WHERE  p.active = true
    AND  (
           p.id IN (SELECT project_id FROM keep)
           -- Nothing to narrow to: fall back to every active project, which is
           -- exactly the pre-783 dropdown. Narrowing must never be the reason
           -- somebody cannot record their time.
           OR NOT EXISTS (SELECT 1 FROM keep)
         )
  ORDER  BY p.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_timesheet_projects(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_timesheet_projects(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid, date, date) IS
  'Mig 787: the projects offered in this employee''s timesheet dropdown for the '
  'period being recorded, plus member_spells -- every membership stint '
  'overlapping that period, as [{from,to}], so the screen can apply the '
  'allocation window per DAY rather than per month. NULL member_spells means '
  'the project was reached some other way (already booked, or the all-projects '
  'fallback) and carries no membership restriction. Offers only; the database '
  'still accepts any project id.';


-- The pre-786 arity, kept as a wrapper. The frontend ships on a different
-- workflow from the database, so for a window the old bundle is still calling
-- this. It resolves "today", which is precisely what it did before -- the bug
-- stays reachable for that window rather than the dropdown going empty, and an
-- empty dropdown is not cosmetic when project is a mandatory field. The extra
-- column is harmless to a caller that does not read it.
CREATE FUNCTION public.my_timesheet_projects(p_employee_id uuid)
RETURNS TABLE (
  id            uuid,
  name          text,
  active        boolean,
  start_date    date,
  end_date      date,
  is_member     boolean,
  has_entries   boolean,
  member_spells jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT * FROM public.my_timesheet_projects(p_employee_id, CURRENT_DATE, CURRENT_DATE);
$fn$;

REVOKE ALL ON FUNCTION public.my_timesheet_projects(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_timesheet_projects(uuid) TO authenticated;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid) IS
  'Legacy one-argument form, kept only so a frontend bundle deployed before '
  'mig 786 keeps working. Resolves membership as of today, which is the bug '
  'the three-argument form fixes. Do not call it from new code.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
      AND pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid, p_period_start date, p_period_end date'
      AND pg_get_function_result(p.oid) LIKE '%member_spells%'
  ) THEN
    RAISE EXCEPTION 'mig 787: period-aware my_timesheet_projects missing member_spells';
  END IF;

  -- The legacy arity must survive, or an old bundle empties its dropdown.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_timesheet_projects'
      AND pg_get_function_identity_arguments(p.oid) = 'p_employee_id uuid'
  ) THEN
    RAISE EXCEPTION 'mig 787: legacy my_timesheet_projects(uuid) was not rebuilt';
  END IF;

  RAISE NOTICE 'mig 787: OK -- membership stints reach the screen';
END $mig$;
