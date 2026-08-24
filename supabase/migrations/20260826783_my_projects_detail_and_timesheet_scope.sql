-- =============================================================================
-- Migration 783: give the lead's screen something to say, and narrow the
--                timesheet project dropdown to the projects you are on
--
-- TWO THINGS, ONE MIGRATION
-- ═════════════════════════
-- A. My Projects had exactly three facts on it -- project name, member count,
--    and a list of names. Everything a lead actually wants to know about their
--    own project (what type, running until when, how many of the budgeted hours
--    are gone, who is burning them) already exists in the database and simply
--    was not exposed. Two read functions fix that.
--
-- B. Step 2 of the design: the timesheet project dropdown currently offers
--    every active project to everyone. It should offer the projects you are on.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
-- ──────────────────────────────────
-- No enforcement trigger. The dropdown narrows what is offered; the database
-- still accepts any project id on an entry. Making membership a hard constraint
-- is a separate switch with a much bigger blast radius -- one missing
-- project_members row and somebody cannot record their week -- and it deserves
-- its own migration, its own backfill check and its own test.
--
-- THE LOCKOUT THIS AVOIDS
-- ───────────────────────
-- Project is mandatory on a timesheet entry. A dropdown that resolves to
-- nothing is therefore not an inconvenience, it is a person who cannot record
-- their time. my_timesheet_projects() cannot return an empty list for anyone
-- who could book before:
--
--   1. projects you are a current member of, plus
--   2. projects you have ALREADY booked to -- so opening an old timesheet never
--      loses the project its entries are on, and an ex-member can still correct
--      history, and
--   3. if 1 and 2 are both empty, every active project -- exactly today's
--      behaviour. Someone with no membership rows is no worse off than before.
--
-- CHANGES
-- ───────
--   1. my_staffable_projects_detail()  -- NEW. The screen's header data.
--   2. my_project_members()            -- DROP/CREATE, gains hours_booked.
--   3. my_timesheet_projects(employee) -- NEW. The narrowed dropdown.
--
-- NOT CHANGED
-- ───────────
--   my_staffable_projects()  -- four RLS policies on project_members depend on
--                               it, so it keeps its exact signature. The screen
--                               calls the new _detail function instead.
--   project_member_add / _remove / can_staff_project / staffable_employee_search
--   Any RLS policy. Any report.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The project header the screen was missing
-- ═══════════════════════════════════════════════════════════════════════════
-- A NEW function rather than widening my_staffable_projects(): that one is
-- named in four RLS policies on project_members, and changing a function's OUT
-- columns means DROP first, which those policies would refuse. Widening it
-- would mean dropping and rebuilding the policies to add two display columns --
-- a security change in service of a layout change, which is the wrong trade.
--
-- There is no project code column on `projects`; name is the only identifier.

CREATE OR REPLACE FUNCTION public.my_staffable_projects_detail()
RETURNS TABLE (
  project_id      uuid,
  project_name    text,
  project_type    text,
  start_date      date,
  end_date        date,
  budget_hours    numeric,
  hours_booked    numeric,
  current_members bigint,
  past_members    bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  -- Same gate as my_staffable_projects(), for the same reason: a manager_id set
  -- for reporting purposes must never become a grant on its own.
  IF NOT user_can('projects_mgmt', 'manage_members', NULL) THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      p.id,
      p.name,
      pv.value,
      p.start_date,
      p.end_date,
      p.budget_hours,
      COALESCE(ROUND(bk.minutes / 60.0, 2), 0)::numeric,
      (SELECT count(*) FROM project_members pm
       WHERE pm.project_id = p.id
         AND pm.effective_from <= CURRENT_DATE
         AND (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)),
      (SELECT count(*) FROM project_members pm
       WHERE pm.project_id = p.id
         AND pm.effective_to IS NOT NULL
         AND pm.effective_to < CURRENT_DATE)
    FROM   projects p
    LEFT   JOIN picklist_values pv ON pv.id = p.project_type_id
    LEFT   JOIN LATERAL (
             SELECT SUM(e.hours_minutes)::numeric AS minutes
             FROM   timesheet_entries e
             WHERE  e.project_id = p.id
           ) bk ON true
    WHERE  p.manager_id = v_me
    ORDER  BY p.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_staffable_projects_detail() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_staffable_projects_detail() TO authenticated;

COMMENT ON FUNCTION public.my_staffable_projects_detail() IS
  'Mig 783: my_staffable_projects() plus the fields the My Projects screen '
  'displays -- type, dates, budget and hours booked, current and past member '
  'counts. Same gate, same rows. Kept separate because my_staffable_projects() '
  'is named in RLS policies and must not change shape.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Hours per member
-- ═══════════════════════════════════════════════════════════════════════════
-- A membership list says who is on the project. It does not say who is doing
-- the work. hours_booked is the difference, and it is the column a lead reads
-- first.
--
-- DROP then CREATE, because the OUT columns change and CREATE OR REPLACE cannot
-- do that. Safe here: nothing but the frontend calls this one -- unlike
-- my_staffable_projects(), which four policies depend on.

DROP FUNCTION IF EXISTS public.my_project_members(uuid);

CREATE FUNCTION public.my_project_members(p_project_id uuid)
RETURNS TABLE (
  id             uuid,
  employee_id    uuid,
  employee_name  text,
  employee_code  text,
  effective_from date,
  effective_to   date,
  allocation_pct numeric,
  is_current     boolean,
  has_hours      boolean,
  hours_booked   numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT can_staff_project(p_project_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT pm.id, pm.employee_id, em.name, em.employee_id,
           pm.effective_from, pm.effective_to, pm.allocation_pct,
           (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE),
           -- Drives the button: "Remove" when nothing is booked, "End
           -- assignment" when hours exist and history has to survive.
           COALESCE(bk.minutes, 0) > 0,
           COALESCE(ROUND(bk.minutes / 60.0, 2), 0)::numeric
    FROM   project_members pm
    JOIN   employees em ON em.id = pm.employee_id
    LEFT   JOIN LATERAL (
             SELECT SUM(e.hours_minutes)::numeric AS minutes
             FROM   timesheet_entries  e
             JOIN   timesheet_headers  h ON h.id = e.header_id
             WHERE  e.project_id  = pm.project_id
               AND  h.employee_id = pm.employee_id
           ) bk ON true
    WHERE  pm.project_id = p_project_id
    ORDER  BY (pm.effective_to IS NULL) DESC, em.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_project_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_project_members(uuid) TO authenticated;

COMMENT ON FUNCTION public.my_project_members(uuid) IS
  'Members of one project the caller manages, current first. hours_booked added '
  'in mig 783; has_hours is now derived from the same subquery rather than a '
  'second EXISTS, so the two can never disagree.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The timesheet dropdown, narrowed
-- ═══════════════════════════════════════════════════════════════════════════
-- Takes the employee explicitly because /timesheet/:employeeId lets an approver
-- open somebody else's sheet, and that sheet must offer THEIR projects, not the
-- approver's.

CREATE OR REPLACE FUNCTION public.my_timesheet_projects(p_employee_id uuid)
RETURNS TABLE (
  id          uuid,
  name        text,
  active      boolean,
  start_date  date,
  end_date    date,
  is_member   boolean,
  has_entries boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();

  -- Your own sheet, or one you are entitled to see. SECURITY DEFINER means the
  -- gate has to be explicit -- there is no RLS behind this to catch a mistake.
  --
  -- IS NOT DISTINCT FROM, not `=`. For a login with no employee behind it v_me
  -- is NULL, `p_employee_id = v_me` is NULL, and NULL OR false is NULL, so
  -- `IF NOT (...)` is NULL -- which plpgsql treats as false and falls straight
  -- through the gate. The three-valued-logic hole that lets an unlinked login
  -- read the project list. Caught by test T8.
  IF NOT (is_super_admin()
          OR p_employee_id IS NOT DISTINCT FROM v_me
          OR COALESCE(user_can('timesheet', 'view', p_employee_id), false)
          OR COALESCE(user_can('timesheet', 'edit', p_employee_id), false)) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH mem AS (
    SELECT pm.project_id
    FROM   project_members pm
    WHERE  pm.employee_id    = p_employee_id
      AND  pm.effective_from <= CURRENT_DATE
      AND  (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)
  ),
  booked AS (
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
         EXISTS (SELECT 1 FROM booked b WHERE b.project_id = p.id)
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

REVOKE ALL ON FUNCTION public.my_timesheet_projects(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_timesheet_projects(uuid) TO authenticated;

COMMENT ON FUNCTION public.my_timesheet_projects(uuid) IS
  'Mig 783: the projects offered in this employee''s timesheet dropdown -- '
  'current memberships, plus anything they have already booked to, falling back '
  'to all active projects when both are empty so nobody is locked out. '
  'Offers only; the database still accepts any project id. Enforcement is a '
  'separate switch.';


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_n int;
BEGIN
  FOR v_n IN
    SELECT 1 FROM (VALUES
      ('my_staffable_projects_detail'), ('my_project_members'), ('my_timesheet_projects')
    ) AS f(nm)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = f.nm)
  LOOP
    RAISE EXCEPTION 'mig 783: a function failed to create';
  END LOOP;

  -- my_staffable_projects() must still exist unchanged -- four RLS policies
  -- on project_members name it.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'my_staffable_projects'
      AND pg_get_function_result(p.oid) LIKE '%member_count%'
  ) THEN
    RAISE EXCEPTION 'mig 783: my_staffable_projects() lost its shape -- RLS depends on it';
  END IF;

  RAISE NOTICE 'mig 783: OK -- project detail, member hours, narrowed dropdown';
END $mig$;
