-- =============================================================================
-- Migration : 20260825773_project_members.sql
-- Purpose   : Who is on a project, and who may say so. Step 1 of four.
--
-- WHAT THIS IS FOR
--   Today the only link between a person and a project is timesheet_entries
--   .project_id -- which records what HAPPENED, never what was planned. So:
--   "assigned but logged nothing" is invisible, every employee sees every
--   project in the timesheet dropdown, and there is no per-person allocation to
--   give a project a real denominator. This table is the missing half.
--
-- WHAT THIS MIGRATION DOES NOT DO, DELIBERATELY
--   * The timesheet dropdown still lists every active project (step 2).
--   * Nothing stops an entry against a project you are not a member of (step 2,
--     as its own switch, only once the lists have real rows in them).
--   * Membership grants NO read access (step 3 adds the my_project_team scope).
--   * No email is sent (step 4).
--   Landing the table inert means the first time membership is exercised is not
--   also the first time it can block someone's timesheet.
--
-- MEMBERSHIP IS DATED, AND REMOVAL IS END-DATING
--   Take someone off in September and August's approved timesheet still
--   references that project legitimately. A hard delete rewrites history that a
--   manager already approved. So: effective_from / effective_to, an exclusion
--   constraint against overlapping stints for the same pair (people roll off and
--   back on), and NO delete policy for project leads at all -- the constraint is
--   structural rather than a convention someone has to remember.
--
-- THE RLS TRAP THIS AVOIDS
--   The natural policy is `EXISTS (SELECT 1 FROM projects p WHERE p.id =
--   project_id AND p.manager_id = get_my_employee_id())`. It fails for every
--   project lead. Subqueries in a policy run as the CALLER, and projects carries
--   `POLICY projects_select ... USING (user_can('projects_mgmt','view',NULL))`
--   -- which a lead does not hold, that being the admin screen. The subquery
--   sees nothing, the policy is false, and the save fails with nothing to read.
--   Hence my_staffable_projects(), SECURITY DEFINER, which is both the policy
--   predicate and what the lead's screen reads to list their own projects.
--
-- Depends on : 754 (projects.manager_id), 20260419002 (get_my_employee_id),
--              732 (the permissions_action_check mechanism)
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- 42/43 already rely on it

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 0  Widen permissions_action_check FIRST
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_canonical text[] := ARRAY['view','create','edit','delete','history','lookup',
                              'view_all_pending','edit_all_pending',
                              'bulk_import','bulk_export',
                              'view_inactive','reassign','approve',
                              'view_compliance','view_utilisation','view_projects',
                              'view_project','manage_members',
                              'view_capacity','view_analytics'];
  v_extra   text[];
  v_allowed text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT action), ARRAY[]::text[]) INTO v_extra
  FROM   public.permissions WHERE action IS NOT NULL AND action <> ALL (v_canonical);

  IF COALESCE(array_length(v_extra, 1), 0) > 0 THEN
    RAISE WARNING 'MIG 773: permissions.action holds % value(s) outside the canonical set: %.',
                  array_length(v_extra, 1), array_to_string(v_extra, ', ');
  END IF;

  v_allowed := v_canonical || v_extra;
  EXECUTE 'ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_action_check';
  EXECUTE format('ALTER TABLE public.permissions ADD CONSTRAINT permissions_action_check '
                 'CHECK (action = ANY (%L::text[]))', v_allowed);
  RAISE NOTICE 'MIG 773: permissions_action_check now admits % value(s).', array_length(v_allowed, 1);
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  The table
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.project_members (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid        NOT NULL REFERENCES projects(id)  ON DELETE CASCADE,
  employee_id    uuid        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from date        NOT NULL DEFAULT CURRENT_DATE,
  effective_to   date,
  allocation_pct numeric(5,2) CHECK (allocation_pct IS NULL
                                     OR (allocation_pct > 0 AND allocation_pct <= 100)),
  added_by       uuid        REFERENCES employees(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT project_members_dates_ordered
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- NOT a plain UNIQUE (project_id, employee_id): people leave a project and come
-- back, and each stint is a separate row. What must never happen is two stints
-- that OVERLAP -- that would make "was this person a member on 12 Aug" ambiguous.
DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_members_no_overlap') THEN
    ALTER TABLE public.project_members ADD CONSTRAINT project_members_no_overlap
      EXCLUDE USING gist (
        project_id  WITH =,
        employee_id WITH =,
        daterange(effective_from, COALESCE(effective_to, 'infinity'::date), '[]') WITH &&
      );
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS idx_project_members_project  ON public.project_members (project_id);
CREATE INDEX IF NOT EXISTS idx_project_members_employee ON public.project_members (employee_id);
-- The "who is on this today" lookup every screen makes.
CREATE INDEX IF NOT EXISTS idx_project_members_current
  ON public.project_members (project_id, employee_id) WHERE effective_to IS NULL;

COMMENT ON TABLE public.project_members IS
  'Who is assigned to a project, and when. Distinct from timesheet_entries.project_id, '
  'which records what happened rather than what was planned. Membership does NOT grant '
  'read access -- the Project Summary and Utilisation reports key on the entry, not on '
  'this table (migs 770, 771).';
COMMENT ON COLUMN public.project_members.effective_to IS
  'NULL = still on the project. Removal end-dates rather than deletes: a September '
  'removal must not invalidate an August timesheet a manager already approved.';
COMMENT ON COLUMN public.project_members.allocation_pct IS
  'Optional planned share of this person''s capacity. Unused today; this is what would '
  'give a project report a real per-person denominator (design doc s8.1b).';

DROP TRIGGER IF EXISTS trg_project_members_updated_at ON public.project_members;
CREATE TRIGGER trg_project_members_updated_at
  BEFORE UPDATE ON public.project_members
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();   -- 20260419001, as every other table uses

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  Backfill from what actually happened
--
-- MANDATORY, not a nicety. Everyone has already booked to projects with no
-- membership anywhere. Without this, the moment step 2 lands, the first person
-- to open an old month finds the project gone and cannot save an edit. Seeded
-- from the first date each person logged to each project, so history stays
-- valid all the way back.
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.project_members (project_id, employee_id, effective_from)
SELECT e.project_id, h.employee_id, min(e.entry_date)
FROM   timesheet_entries e
JOIN   timesheet_headers h ON h.id = e.header_id
WHERE  e.project_id IS NOT NULL
  AND  EXISTS (SELECT 1 FROM projects  p  WHERE p.id  = e.project_id)
  AND  EXISTS (SELECT 1 FROM employees em WHERE em.id = h.employee_id)
GROUP  BY e.project_id, h.employee_id
ON CONFLICT DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3  The permission
--
-- NOT projects_mgmt.edit, which would let a lead rename any project, change its
-- dates and budget, and reassign its manager -- including to themselves.
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.permissions (module_id, code, name, description, action, sort_order)
SELECT m.id,
       'projects_mgmt.manage_members',
       'Manage Project Members',
       'Add and remove people on projects where this person is the Reporting '
       'Manager. Scoped by the project''s manager field, not by a target group. '
       'Grants no visibility of anyone''s data on its own.',
       'manage_members',
       50
FROM   public.modules m
WHERE  m.code = 'projects_mgmt'
ON CONFLICT (code) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4  The predicate -- policy and screen read the same thing
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.my_staffable_projects()
RETURNS TABLE (project_id uuid, project_name text, member_count bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_me uuid;
BEGIN
  -- Gate first, so a manager_id set for reporting purposes never becomes a
  -- write grant on its own.
  IF NOT user_can('projects_mgmt', 'manage_members', NULL) THEN
    RETURN;
  END IF;

  v_me := get_my_employee_id();
  IF v_me IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT p.id, p.name,
           (SELECT count(*) FROM project_members pm
            WHERE pm.project_id = p.id AND pm.effective_to IS NULL)
    FROM   projects p
    WHERE  p.manager_id = v_me
    ORDER  BY p.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_staffable_projects() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_staffable_projects() TO authenticated;

COMMENT ON FUNCTION public.my_staffable_projects() IS
  'Mig 773: projects this caller may staff. SECURITY DEFINER because it must read '
  '`projects`, whose RLS requires projects_mgmt.view -- a permission a project lead '
  'does not hold. Used as the RLS predicate on project_members AND as the lead''s '
  'project list. Empty unless projects_mgmt.manage_members is granted AND the caller '
  'is an employee AND at least one project names them as Reporting Manager.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5  RLS
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.project_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS project_members_select ON public.project_members;
CREATE POLICY project_members_select ON public.project_members FOR SELECT
  USING (
    is_super_admin()
    OR user_can('projects_mgmt', 'view', NULL)              -- project admins
    OR project_id IN (SELECT project_id FROM my_staffable_projects())
    OR employee_id = get_my_employee_id()                    -- your own assignments
  );

DROP POLICY IF EXISTS project_members_insert ON public.project_members;
CREATE POLICY project_members_insert ON public.project_members FOR INSERT
  WITH CHECK (
    is_super_admin()
    OR project_id IN (SELECT project_id FROM my_staffable_projects())
  );

-- USING *and* WITH CHECK, both. With USING alone a lead could take a row on
-- their own project and rewrite project_id to someone else's -- it passes the
-- old-row test and lands outside their control. That is the commonest RLS
-- mistake there is, and it is invisible until somebody tries it.
DROP POLICY IF EXISTS project_members_update ON public.project_members;
CREATE POLICY project_members_update ON public.project_members FOR UPDATE
  USING (
    is_super_admin()
    OR project_id IN (SELECT project_id FROM my_staffable_projects())
  )
  WITH CHECK (
    is_super_admin()
    OR project_id IN (SELECT project_id FROM my_staffable_projects())
  );

-- No DELETE policy. Removal is end-dating, and leaving the door shut makes that
-- structural instead of a rule someone has to remember. The one honest delete --
-- a lead adds the wrong person and fixes it before any hours exist -- goes
-- through an RPC in the next migration, which can tell the two cases apart.
DROP POLICY IF EXISTS project_members_delete ON public.project_members;

GRANT SELECT, INSERT, UPDATE ON public.project_members TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  v_src     text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_name = 'project_members') THEN
    v_missing := v_missing || 'the table was not created'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_members_no_overlap') THEN
    v_missing := v_missing || 'overlapping stints are possible -- "was X a member on date D" would be ambiguous'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code = 'projects_mgmt.manage_members') THEN
    v_missing := v_missing || 'the manage_members permission was not seeded'::text; END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'my_staffable_projects';
  IF v_src IS NULL THEN
    v_missing := v_missing || 'my_staffable_projects() is missing'::text;
  ELSE
    IF position('''projects_mgmt'', ''manage_members''' IN v_src) = 0 THEN
      v_missing := v_missing || 'the predicate does not check the grant'::text; END IF;
    IF position('SECURITY DEFINER' IN v_src) = 0 THEN
      v_missing := v_missing || 'the predicate is not SECURITY DEFINER -- it cannot read projects for a lead'::text; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'project_members' AND rowsecurity) THEN
    v_missing := v_missing || 'RLS is not enabled on project_members'::text; END IF;

  -- UPDATE must carry BOTH qualifiers, or a lead can move a row to another project.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'project_members' AND policyname = 'project_members_update'
                   AND qual IS NOT NULL AND with_check IS NOT NULL) THEN
    v_missing := v_missing || 'the UPDATE policy is missing USING or WITH CHECK -- a lead could move a row to another project'::text; END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
             WHERE tablename = 'project_members' AND cmd = 'DELETE') THEN
    v_missing := v_missing || 'a DELETE policy exists -- removal must be end-dating'::text; END IF;

  -- The reports must NOT have started reading membership. Visibility keys on the
  -- entry, or hours by a non-member become invisible to the only person who
  -- could add them.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('timesheet_report_utilisation','timesheet_report_project_summary')
      AND pg_get_functiondef(p.oid) LIKE '%project_members%'
  ) THEN
    v_missing := v_missing || 'a report reads project_members -- membership must not gate visibility'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 773 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 773 verified: project_members exists, leads own their own rows, nothing reads it yet.';
END $mig$;

COMMIT;
