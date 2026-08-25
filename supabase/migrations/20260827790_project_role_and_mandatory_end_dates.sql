-- =============================================================================
-- Migration 790: a role on every assignment, an end date on every project
--
-- WHAT THIS IS
-- ════════════
-- The data half of the Team Allocation work. It creates the things the new
-- screens need to exist before any UI can be written against them:
--
--   1. a PROJECT_ROLE picklist, admin-editable like every other reference list
--   2. project_members.role_id, guarded to that picklist
--   3. every existing assignment backfilled to EC Consultant
--   4. every project without an end date backfilled, then end_date made NOT NULL
--   5. role exposed on the read API and accepted by add / update
--
-- ON THE BACKFILL, HONESTLY
-- ─────────────────────────
-- Backfilling role to 'EC Consultant' writes a fact the system does not know.
-- Some of those people were ABAPERs. That is a deliberate trade -- the column
-- is mandatory going forward and a NULL would be worse -- but it has one
-- consequence worth stating out loud: **role-based reporting is not
-- trustworthy until leads correct the existing rows.** The new screen makes
-- that a two-click fix per person, and until it is done "hours by role" will
-- say almost everything was EC Consultant.
--
-- ON THE END-DATE BACKFILL
-- ────────────────────────
-- 31 Dec 2026 for every project with no end date -- EXCEPT where somebody has
-- already booked time beyond that date. Mig 788's guard would refuse those
-- (correctly: the edit would strand their hours), and a migration that fails on
-- real data is not a migration. Those projects get their last booked day
-- instead, and the migration says which and why. Nobody's hours are stranded
-- and no project is left without an end date.
--
-- WHY end_date CAN BE NOT NULL SAFELY
-- ───────────────────────────────────
-- The admin Projects form already refuses to save without one
-- ('End date is required.', Projects.tsx). The database is being told what the
-- only writer already enforces, which is the safe direction for a NOT NULL.
--
-- CHANGES
-- ───────
--   PROJECT_ROLE picklist + 5 values      seeded, system, house-rule ref_ids
--   project_members.role_id               FK + guard trigger + backfill
--   projects.end_date                     backfilled, then NOT NULL
--   my_project_members()                  returns role_id + role_name
--   project_member_add()                  takes p_role_id
--   project_member_update()               takes p_role_id
--
-- NOT CHANGED
-- ───────────
--   The permission verbs -- that is its own migration, and it touches security.
--   Any report. Any timesheet function. projects.start_date stays optional.
-- =============================================================================

SET jit = 'off';


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The picklist
-- ═══════════════════════════════════════════════════════════════════════════
-- system = true suppresses Edit and Delete on the picklist ITSELF in Reference
-- Data while leaving its values fully editable -- the same treatment mig 760
-- had to retrofit onto PROJECT_TYPE because 755 forgot it.
--
-- ref_ids follow the house rule (first letter of the picklist, three digits).
-- (picklist_id, ref_id) is unique PER PICKLIST, so P001 here does not collide
-- with PROJECT_TYPE's P001. Reports must key on ref_id, never on `value` --
-- the label is admin-editable by design.

INSERT INTO picklists (picklist_id, name, system)
VALUES ('PROJECT_ROLE', 'Project Role', true)
ON CONFLICT (picklist_id) DO UPDATE SET system = true;

INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT p.id, v.label, v.ref, true
FROM   picklists p
CROSS  JOIN (VALUES ('EC Consultant',   'P001'),
                    ('PMGM Consultant', 'P002'),
                    ('LMS Consultant',  'P003'),
                    ('ABAPER',          'P004'),
                    ('ECP Consultant',  'P005')) AS v(label, ref)
WHERE  p.picklist_id = 'PROJECT_ROLE'
  AND  NOT EXISTS (SELECT 1 FROM picklist_values pv
                   WHERE pv.picklist_id = p.id AND pv.ref_id = v.ref);


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The column
-- ═══════════════════════════════════════════════════════════════════════════
-- ON DELETE RESTRICT, not SET NULL. Role is mandatory: SET NULL would answer
-- "somebody deleted a reference value" by quietly emptying a required field on
-- rows nobody was looking at. RESTRICT makes the deletion the thing that fails,
-- in front of the person doing it -- and Reference Data can deactivate a value
-- instead, which is what `active` is for.

ALTER TABLE project_members ADD COLUMN IF NOT EXISTS role_id uuid;

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_members_role_id_fkey') THEN
    ALTER TABLE project_members ADD CONSTRAINT project_members_role_id_fkey
      FOREIGN KEY (role_id) REFERENCES picklist_values(id) ON DELETE RESTRICT;
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS idx_project_members_role ON project_members (role_id);

-- The FK proves it is A picklist value. This proves it is one of THESE.
CREATE OR REPLACE FUNCTION public.project_members_role_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  IF NEW.role_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM picklist_values pv
    JOIN   picklists p ON p.id = pv.picklist_id
    WHERE  pv.id = NEW.role_id AND p.picklist_id = 'PROJECT_ROLE'
  ) THEN
    RAISE EXCEPTION 'Project role must be a value from the Project Role reference list.';
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS before_project_members_role_guard ON project_members;

CREATE TRIGGER before_project_members_role_guard
BEFORE INSERT OR UPDATE OF role_id
ON project_members
FOR EACH ROW
EXECUTE FUNCTION project_members_role_guard();


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Backfill the role
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_ec  uuid;
  v_n   int;
BEGIN
  SELECT pv.id INTO v_ec
  FROM   picklist_values pv
  JOIN   picklists p ON p.id = pv.picklist_id
  WHERE  p.picklist_id = 'PROJECT_ROLE' AND pv.ref_id = 'P001';

  IF v_ec IS NULL THEN
    RAISE EXCEPTION 'mig 790: EC Consultant (P001) missing -- the seed did not take';
  END IF;

  UPDATE project_members SET role_id = v_ec WHERE role_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RAISE NOTICE 'mig 790: % existing assignment(s) defaulted to EC Consultant. '
               'Hours-by-role is unreliable until leads correct these.', v_n;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Every project gets an end date, and then must have one
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  r      RECORD;
  v_end  date;
  v_n    int := 0;
  v_late int := 0;
BEGIN
  FOR r IN SELECT id, name FROM projects WHERE end_date IS NULL LOOP
    -- 31 Dec 2026, unless somebody has booked past it -- mig 788's guard would
    -- refuse that edit, and it would be right to.
    SELECT GREATEST(DATE '2026-12-31', COALESCE(MAX(e.entry_date), DATE '2026-12-31'))
    INTO   v_end
    FROM   timesheet_entries e
    WHERE  e.project_id = r.id;

    UPDATE projects SET end_date = v_end WHERE id = r.id;
    v_n := v_n + 1;

    IF v_end <> DATE '2026-12-31' THEN
      v_late := v_late + 1;
      RAISE NOTICE 'mig 790: % ends % rather than 2026-12-31 -- hours are booked that far out.',
                   r.name, v_end;
    END IF;
  END LOOP;

  RAISE NOTICE 'mig 790: % project(s) given an end date (% beyond 2026-12-31).', v_n, v_late;
END $mig$;

ALTER TABLE projects ALTER COLUMN end_date SET NOT NULL;

COMMENT ON COLUMN projects.end_date IS
  'Mandatory since mig 790. The admin Projects form already required it; the '
  'database now agrees. Member assignments default their end date from this.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Role on the read API
-- ═══════════════════════════════════════════════════════════════════════════
-- DROP/CREATE because the OUT columns change. Only the frontend reads this one.

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
  hours_booked   numeric,
  role_id        uuid,
  role_name      text
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
           COALESCE(bk.minutes, 0) > 0,
           COALESCE(ROUND(bk.minutes / 60.0, 2), 0)::numeric,
           pm.role_id, rv.value
    FROM   project_members pm
    JOIN   employees em ON em.id = pm.employee_id
    LEFT   JOIN picklist_values rv ON rv.id = pm.role_id
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
  'Members of one project the caller manages, current first, with hours booked '
  'and the project role (mig 790). role_name is the admin-editable label -- key '
  'reports on the picklist ref_id, never on this.';


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Role on the write API
-- ═══════════════════════════════════════════════════════════════════════════
-- Both functions gain a defaulted parameter, which means DROP and recreate --
-- a new overload would make existing 2- and 4-argument calls ambiguous. Bodies
-- are taken from the LIVE definitions and transformed, not retyped: 789 and 788
-- patched these, and a body pasted from the files would silently revert them.

-- Anchors are matched against pg_get_functiondef's NORMALISED output, which is
-- not the source text: it collapses the parameter list onto one line and spells
-- defaults with their cast (NULL::numeric, not NULL). Every hit count divides
-- by length(anchor) -- an earlier draft of this migration hardcoded those
-- lengths and got a meaningless count that happened to read zero.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a_add_sig text := 'p_allocation_pct numeric DEFAULT NULL::numeric)';
  r_add_sig text := 'p_allocation_pct numeric DEFAULT NULL::numeric, p_role_id uuid DEFAULT NULL::uuid)';

  a_add_ins text := 'INSERT INTO project_members (project_id, employee_id, effective_from, allocation_pct, added_by)';
  r_add_ins text := 'INSERT INTO project_members (project_id, employee_id, effective_from, allocation_pct, role_id, added_by)';

  a_add_val text := 'VALUES (p_project_id, p_employee_id, p_effective_from, p_allocation_pct, get_my_employee_id())';
  r_add_val text := 'VALUES (p_project_id, p_employee_id, p_effective_from, p_allocation_pct, p_role_id, get_my_employee_id())';

  a_upd_sig text := 'p_clear_effective_to boolean DEFAULT false)';
  r_upd_sig text := 'p_clear_effective_to boolean DEFAULT false, p_role_id uuid DEFAULT NULL::uuid)';

  a_upd_set text := E'  UPDATE project_members\n  SET    allocation_pct = v_alloc,';
  r_upd_set text := E'  UPDATE project_members\n  SET    role_id        = COALESCE(p_role_id, v_row.role_id),\n         allocation_pct = v_alloc,';
BEGIN
  -- ── project_member_add ────────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 790: project_member_add not found';
  END IF;

  IF position('p_role_id' in v_src) > 0 THEN
    RAISE NOTICE 'mig 790: project_member_add already takes a role -- skipping';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_add_sig, ''))) / NULLIF(length(a_add_sig), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 790: add signature anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_src, a_add_sig, r_add_sig);

    v_hits := (length(v_new) - length(replace(v_new, a_add_ins, ''))) / NULLIF(length(a_add_ins), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 790: add INSERT anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_new, a_add_ins, r_add_ins);

    v_hits := (length(v_new) - length(replace(v_new, a_add_val, ''))) / NULLIF(length(a_add_val), 0);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'mig 790: add VALUES anchor matched % times, expected 1', v_hits;
    END IF;
    v_new := replace(v_new, a_add_val, r_add_val);

    DROP FUNCTION IF EXISTS public.project_member_add(uuid, uuid, date, numeric);
    EXECUTE v_new;
    EXECUTE 'REVOKE ALL ON FUNCTION public.project_member_add(uuid, uuid, date, numeric, uuid) FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.project_member_add(uuid, uuid, date, numeric, uuid) TO authenticated';
  END IF;

  -- ── project_member_update ─────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_update';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 790: project_member_update not found';
  END IF;

  IF position('p_role_id' in v_src) > 0 THEN
    RAISE NOTICE 'mig 790: project_member_update already takes a role -- skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_upd_sig, ''))) / NULLIF(length(a_upd_sig), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 790: update signature anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a_upd_sig, r_upd_sig);

  -- NULL means leave alone, as it does for every other field here. Role has no
  -- clear flag: it is mandatory, so there is no state to clear it to.
  v_hits := (length(v_new) - length(replace(v_new, a_upd_set, ''))) / NULLIF(length(a_upd_set), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 790: update SET anchor matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a_upd_set, r_upd_set);

  DROP FUNCTION IF EXISTS public.project_member_update(uuid, numeric, boolean, date, date, boolean);
  EXECUTE v_new;
  EXECUTE 'REVOKE ALL ON FUNCTION public.project_member_update(uuid, numeric, boolean, date, date, boolean, uuid) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.project_member_update(uuid, numeric, boolean, date, date, boolean, uuid) TO authenticated';
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM   picklist_values pv JOIN picklists p ON p.id = pv.picklist_id
  WHERE  p.picklist_id = 'PROJECT_ROLE';
  IF v_n < 5 THEN
    RAISE EXCEPTION 'mig 790: expected 5 project roles, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM project_members WHERE role_id IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig 790: % assignment(s) still have no role', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM projects WHERE end_date IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig 790: % project(s) still have no end date', v_n;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_add'
      AND pg_get_function_identity_arguments(p.oid) LIKE '%p_role_id uuid%') THEN
    RAISE EXCEPTION 'mig 790: project_member_add does not take a role';
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'project_member_update') <> 1 THEN
    RAISE EXCEPTION 'mig 790: project_member_update has more than one overload';
  END IF;

  RAISE NOTICE 'mig 790: OK -- roles exist, every project has an end date';
END $mig$;
