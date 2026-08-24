-- =============================================================================
-- Migration : 20260825774_project_member_admin_api.sql
-- Purpose   : The four calls the "My Projects" screen makes. Step 1, part 2.
--
-- WHY THESE ARE FUNCTIONS AND NOT PLAIN TABLE READS
--   A project lead holds projects_mgmt.manage_members and nothing else. That
--   leaves them unable to read two tables the screen obviously needs:
--
--     projects   POLICY projects_select  USING (user_can('projects_mgmt','view',NULL))
--     employees  POLICY employees_select USING (... user_can('employee_details','view', id))
--
--   So a lead cannot see their own project's NAME, nor the name of anyone they
--   are staffing. Both reads have to be SECURITY DEFINER, and being definer,
--   the checks inside them ARE the security -- there is no RLS underneath to
--   catch a mistake. Every one starts with the same gate.
--
-- WHAT THE PICKER RETURNS, AND WHAT IT DOES NOT
--   id, name, employee code. No department, no designation, no manager. A lead
--   staffing across departments legitimately needs to FIND people outside their
--   HR scope; that is not the same as being told where those people sit. Same
--   line mig 771 draws when it redacts department on project-reached rows.
--
-- REMOVAL DECIDES FOR ITSELF
--   773 deliberately left no DELETE policy, so removal is end-dating. But a lead
--   who adds the wrong person and notices two minutes later should not leave a
--   zero-length stint behind forever. project_member_remove() looks for hours:
--   any entry against that project by that person and it end-dates; none and it
--   deletes. Conditional rule, one place, no RLS gymnastics.
--
-- Depends on : 773
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1  One gate, used by all four
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.can_staff_project(p_project_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_project_id IS NULL THEN RETURN false; END IF;
  IF is_super_admin() THEN RETURN true; END IF;
  -- The admin door: whoever may edit projects may also staff them.
  IF user_can('projects_mgmt', 'edit', NULL) THEN RETURN true; END IF;
  -- The lead door: the grant AND this project naming them.
  RETURN EXISTS (SELECT 1 FROM my_staffable_projects() m WHERE m.project_id = p_project_id);
END;
$fn$;

REVOKE ALL ON FUNCTION public.can_staff_project(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_staff_project(uuid) TO authenticated;

COMMENT ON FUNCTION public.can_staff_project(uuid) IS
  'Mig 774: may this caller manage membership of this project. Super admin, or '
  'projects_mgmt.edit, or projects_mgmt.manage_members plus being the project''s '
  'Reporting Manager. The single gate every member-admin call opens with.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2  Read: who is on this project
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.my_project_members(p_project_id uuid)
RETURNS TABLE (
  id             uuid,
  employee_id    uuid,
  employee_name  text,
  employee_code  text,
  effective_from date,
  effective_to   date,
  allocation_pct numeric,
  is_current     boolean,
  has_hours      boolean
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
           EXISTS (
             SELECT 1 FROM timesheet_entries e
             JOIN   timesheet_headers h ON h.id = e.header_id
             WHERE  e.project_id = pm.project_id
               AND  h.employee_id = pm.employee_id)
    FROM   project_members pm
    JOIN   employees em ON em.id = pm.employee_id
    WHERE  pm.project_id = p_project_id
    ORDER  BY (pm.effective_to IS NULL) DESC, em.name;
END;
$fn$;

REVOKE ALL ON FUNCTION public.my_project_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_project_members(uuid) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3  Read: the employee picker
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.staffable_employee_search(p_query text)
RETURNS TABLE (employee_id uuid, employee_name text, employee_code text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT user_can('projects_mgmt', 'manage_members', NULL)
     AND NOT user_can('projects_mgmt', 'edit', NULL)
     AND NOT is_super_admin() THEN
    RETURN;
  END IF;

  -- Second gate: holding the grant is not enough, you must actually manage
  -- something. Otherwise the permission alone becomes a company directory.
  IF NOT is_super_admin()
     AND NOT user_can('projects_mgmt', 'edit', NULL)
     AND NOT EXISTS (SELECT 1 FROM my_staffable_projects()) THEN
    RETURN;
  END IF;

  IF p_query IS NULL OR length(btrim(p_query)) < 2 THEN
    RETURN;                      -- no blank-query directory dump
  END IF;

  RETURN QUERY
    SELECT e.id, e.name, e.employee_id
    FROM   employees e
    WHERE  e.status = 'Active'
      AND  e.deleted_at IS NULL
      AND  (e.name ILIKE '%' || btrim(p_query) || '%'
            OR e.employee_id ILIKE '%' || btrim(p_query) || '%')
    ORDER  BY e.name
    LIMIT  20;
END;
$fn$;

REVOKE ALL ON FUNCTION public.staffable_employee_search(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staffable_employee_search(text) TO authenticated;

COMMENT ON FUNCTION public.staffable_employee_search(text) IS
  'Mig 774: find someone to put on a project. Name and code only -- never '
  'department, designation or manager. A lead staffing across departments needs '
  'to find people outside their HR scope; that is not the same as being told '
  'where those people sit (the line mig 771 draws).';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4  Write: add
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.project_member_add(
  p_project_id     uuid,
  p_employee_id    uuid,
  p_effective_from date    DEFAULT CURRENT_DATE,
  p_allocation_pct numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF NOT can_staff_project(p_project_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You can only staff projects where you are the Reporting Manager.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM employees e
                 WHERE e.id = p_employee_id AND e.status = 'Active' AND e.deleted_at IS NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_ACTIVE',
      'message', 'That person is not an active employee.');
  END IF;

  -- Caught here so the user reads a sentence rather than an exclusion-constraint
  -- violation. The constraint still stands behind it.
  IF EXISTS (
    SELECT 1 FROM project_members pm
    WHERE  pm.project_id = p_project_id
      AND  pm.employee_id = p_employee_id
      AND  daterange(pm.effective_from, COALESCE(pm.effective_to, 'infinity'::date), '[]')
           && daterange(p_effective_from, 'infinity'::date, '[]')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_ON_PROJECT',
      'message', 'That person is already on this project for an overlapping period. '
                 'End the current assignment first if they are rejoining.');
  END IF;

  INSERT INTO project_members (project_id, employee_id, effective_from, allocation_pct, added_by)
  VALUES (p_project_id, p_employee_id, p_effective_from, p_allocation_pct, get_my_employee_id())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$fn$;

REVOKE ALL ON FUNCTION public.project_member_add(uuid, uuid, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_member_add(uuid, uuid, date, numeric) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5  Write: remove, deciding for itself
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.project_member_remove(
  p_id           uuid,
  p_effective_to date DEFAULT CURRENT_DATE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row       project_members%ROWTYPE;
  v_has_hours boolean;
  v_end       date;
BEGIN
  SELECT * INTO v_row FROM project_members WHERE id = p_id;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'That assignment no longer exists.');
  END IF;

  IF NOT can_staff_project(v_row.project_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You can only staff projects where you are the Reporting Manager.');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM timesheet_entries e
    JOIN   timesheet_headers h ON h.id = e.header_id
    WHERE  e.project_id = v_row.project_id
      AND  h.employee_id = v_row.employee_id
  ) INTO v_has_hours;

  IF NOT v_has_hours THEN
    -- Nothing was ever booked, so nothing is being rewritten.
    DELETE FROM project_members WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'action', 'deleted');
  END IF;

  -- Never before the stint began: an end date earlier than the start would
  -- violate the ordering check and means "today" on a same-day assignment.
  v_end := GREATEST(COALESCE(p_effective_to, CURRENT_DATE), v_row.effective_from);

  UPDATE project_members SET effective_to = v_end WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'action', 'ended', 'effective_to', v_end);
END;
$fn$;

REVOKE ALL ON FUNCTION public.project_member_remove(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.project_member_remove(uuid, date) TO authenticated;

COMMENT ON FUNCTION public.project_member_remove(uuid, date) IS
  'Mig 774: end-dates when hours exist against the project, deletes when none do. '
  '773 leaves no DELETE policy on purpose, so this is the only door -- and it is '
  'the only place that can tell a real removal from a two-minute-old mistake.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_missing text[] := '{}';
  r         record;
BEGIN
  FOR r IN
    SELECT unnest(ARRAY['can_staff_project','my_project_members',
                        'staffable_employee_search','project_member_add',
                        'project_member_remove']) AS nm
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.proname = r.nm) THEN
      v_missing := v_missing || format('%s() is missing', r.nm);
    ELSIF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = r.nm AND p.prosecdef) THEN
      -- Not pedantry: without definer they cannot read projects or employees for
      -- a lead, and the screen silently shows nothing.
      v_missing := v_missing || format('%s() is not SECURITY DEFINER', r.nm);
    END IF;
  END LOOP;

  -- Every one of them is definer, so each must gate itself.
  FOR r IN
    SELECT p.proname AS nm, pg_get_functiondef(p.oid) AS src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('my_project_members','project_member_add','project_member_remove')
  LOOP
    IF position('can_staff_project' IN r.src) = 0 THEN
      v_missing := v_missing || format('%s() does not open with the gate', r.nm);
    END IF;
  END LOOP;

  -- The picker must not hand back HR attributes.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'staffable_employee_search'
      AND (pg_get_functiondef(p.oid) LIKE '%dept_id%'
        OR pg_get_functiondef(p.oid) LIKE '%department%'
        OR pg_get_functiondef(p.oid) LIKE '%designation%')
  ) THEN
    v_missing := v_missing || 'the picker returns HR attributes -- name and code only'::text; END IF;

  -- 773 must still hold.
  IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'project_members' AND cmd = 'DELETE') THEN
    v_missing := v_missing || 'mig 773: a DELETE policy appeared -- removal must go through the RPC'::text; END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'MIG 774 ABORT:\n  - %', array_to_string(v_missing, E'\n  - ');
  END IF;

  RAISE NOTICE 'MIG 774 verified: four gated calls, each one checking for itself.';
END $mig$;

COMMIT;
