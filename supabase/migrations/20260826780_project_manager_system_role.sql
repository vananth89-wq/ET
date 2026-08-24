-- =============================================================================
-- Migration 780: `Project Manager` — a self-maintaining system role
--
-- PIECE 1 of 3 (see docs/project-manager-persona-design.md)
--
-- WHAT THIS DOES
-- ══════════════
-- Adds a system role whose membership is derived from data, never typed:
--
--     you are a Project Manager  <=>  your name is in the Reporting Manager
--                                     field of at least one active project
--
-- Modelled exactly on the existing `manager` role, whose rule is "has >= 1
-- active direct report".  Nobody is ever added to that role by hand and nobody
-- should ever be added to this one either -- a hand-maintained list of leads is
-- the precise failure this design exists to remove.
--
-- WHAT THIS DOES *NOT* DO
-- ───────────────────────
-- The role by itself grants NOTHING.  It is only the "who".  The "what" and
-- the "whose" still come from a permission set assigned to it, which needs the
-- `project_members` target group -- Piece 2, a later migration.  Until Piece 2
-- lands, this role is inert by design.
--
-- CHANGES
-- ───────
--   1. INSERT roles                -- code='project_manager', role_type='system'
--   2. PATCH  sync_system_roles()  -- fourth branch, in place, anchored
--   3. NEW    trg_projects_sync_roles() + trigger on projects
--   4. Initial sync
--
-- NOT CHANGED
-- ───────────
--   user_can(), get_target_population()  -- Piece 2
--   Any report function                  -- Piece 3
--   Any RLS policy
--   Any existing role's membership       -- the three existing branches are
--                                           patched around, never rewritten
--
-- FRONTEND
-- ────────
--   `Grant access to` picks the role up for free (it reads the roles table).
--   The Sync button appears for free (it renders when role_type === 'system').
--   BUT: PermissionMatrix.getRoleCategory() buckets by substring, and
--   'project_manager' contains 'manager' -> it lands in the 'mss' bucket and is
--   offered Direct L1 / L2 / All levels / Same dept / Everyone, with no escape
--   hatch.  That is a real gap and is fixed alongside Piece 2, not here.
-- =============================================================================

SET jit = 'off';


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The role
-- ─────────────────────────────────────────────────────────────────────────────
-- editable=false: membership is derived, so hand-editing it would be a lie that
-- the next sync silently reverts.  Better to not offer the affordance.

INSERT INTO roles (code, name, description, role_type, is_system, active, editable, sort_order)
VALUES (
  'project_manager',
  'Project Manager',
  'Named as Reporting Manager on at least one active project. '
  'Membership is derived from the project record and cannot be edited by hand.',
  'system', true, true, false, 8
)
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      role_type   = EXCLUDED.role_type,
      is_system   = EXCLUDED.is_system,
      editable    = EXCLUDED.editable,
      sort_order  = EXCLUDED.sort_order;
      -- `active` deliberately left alone, matching mig 20260422004


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Patch sync_system_roles() IN PLACE
-- ─────────────────────────────────────────────────────────────────────────────
-- Deliberately NOT a CREATE OR REPLACE of the whole body.  Migration 061 is the
-- last file in this repo that defines the function, but "last file that defines
-- it" is not the same as "what is running on the server", and pasting a stale
-- body over a live one is how migrations 734/736/737 silently reverted work
-- that had already shipped.
--
-- So: read the live definition, apply four anchored substitutions, assert each
-- one hit exactly once, and abort the whole migration if any anchor is missing
-- or ambiguous.  A failed assert here is a *good* outcome -- it means the live
-- function is not what we thought and a human should look before we rewrite it.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;
  v_hits  int;

  -- ── anchor 1: extra locals (role id + the three counters) ─────────────────
  a1 text := '  v_mgr_eligible  int := 0;  v_mgr_inserted  int := 0;  v_mgr_deleted  int := 0;';
  r1 text := '  v_pm_id    uuid;' || E'\n'
           || '  v_mgr_eligible  int := 0;  v_mgr_inserted  int := 0;  v_mgr_deleted  int := 0;'
           || E'\n'
           || '  v_pm_eligible   int := 0;  v_pm_inserted   int := 0;  v_pm_deleted   int := 0;';

  -- ── anchor 2: resolve the role id ─────────────────────────────────────────
  a2 text := '  SELECT id INTO v_mgr_id FROM roles WHERE code = ''manager''   LIMIT 1;';
  r2 text := '  SELECT id INTO v_mgr_id FROM roles WHERE code = ''manager''   LIMIT 1;'
           || E'\n'
           || '  SELECT id INTO v_pm_id  FROM roles WHERE code = ''project_manager'' LIMIT 1;';

  -- ── anchor 3: the new branch, inserted just before END LOOP ───────────────
  a3 text := E'\n  END LOOP;';
  r3 text := E'\n'
    || '    -- ────────────────────────────────────────────────────────────────────────' || E'\n'
    || '    -- Project Manager role -- named as Reporting Manager on >= 1 active project' || E'\n'
    || '    -- ────────────────────────────────────────────────────────────────────────' || E'\n'
    || '    IF (p_role_code IS NULL OR p_role_code = ''project_manager'') AND v_pm_id IS NOT NULL THEN' || E'\n'
    || '      IF v_emp.status = ''Active'' AND v_emp.deleted_at IS NULL AND EXISTS (' || E'\n'
    || '        SELECT 1 FROM projects p' || E'\n'
    || '        WHERE  p.manager_id = v_emp.id' || E'\n'
    || '          AND  p.active     = true' || E'\n'
    || '      ) THEN' || E'\n'
    || '        v_pm_eligible := v_pm_eligible + 1;' || E'\n'
    || E'\n'
    || '        INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)' || E'\n'
    || '        VALUES (v_profile.profile_id, v_pm_id, ''system'', now(), now())' || E'\n'
    || '        ON CONFLICT (profile_id, role_id) DO NOTHING;' || E'\n'
    || E'\n'
    || '        IF FOUND THEN' || E'\n'
    || '          v_pm_inserted := v_pm_inserted + 1;' || E'\n'
    || '        END IF;' || E'\n'
    || '      ELSE' || E'\n'
    || '        DELETE FROM user_roles' || E'\n'
    || '        WHERE  profile_id        = v_profile.profile_id' || E'\n'
    || '          AND  role_id           = v_pm_id' || E'\n'
    || '          AND  assignment_source = ''system'';' || E'\n'
    || E'\n'
    || '        IF FOUND THEN' || E'\n'
    || '          v_pm_deleted := v_pm_deleted + 1;' || E'\n'
    || '        END IF;' || E'\n'
    || '      END IF;' || E'\n'
    || '    END IF;' || E'\n'
    || E'\n  END LOOP;';

  -- ── anchor 4: the returned summary ────────────────────────────────────────
  a4 text := '  RETURN result;';
  r4 text := '  IF p_role_code IS NULL OR p_role_code = ''project_manager'' THEN' || E'\n'
    || '    result := result || jsonb_build_object(''project_manager'', jsonb_build_object(' || E'\n'
    || '      ''eligible'', v_pm_eligible, ''inserted'', v_pm_inserted, ''deleted'', v_pm_deleted' || E'\n'
    || '    ));' || E'\n'
    || '  END IF;' || E'\n'
    || E'\n'
    || '  RETURN result;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'sync_system_roles'
    AND  pg_get_function_identity_arguments(p.oid) = 'p_role_code text';

  IF v_src IS NULL THEN
    RAISE EXCEPTION
      'mig 780: sync_system_roles(text) not found -- refusing to guess at its shape';
  END IF;

  -- Already patched?  Then this migration is a no-op, not an error.
  IF position('v_pm_eligible' in v_src) > 0 THEN
    RAISE NOTICE 'mig 780: sync_system_roles already carries the project_manager branch -- skipping patch';
    RETURN;
  END IF;

  -- Declared locals -----------------------------------------------------------
  v_hits := (length(v_src) - length(replace(v_src, a1, ''))) / NULLIF(length(a1), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 780: anchor 1 (locals) matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_src, a1, r1);

  -- Role id lookup ------------------------------------------------------------
  v_hits := (length(v_new) - length(replace(v_new, a2, ''))) / NULLIF(length(a2), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 780: anchor 2 (role id lookup) matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a2, r2);

  -- The branch itself ---------------------------------------------------------
  v_hits := (length(v_new) - length(replace(v_new, a3, ''))) / NULLIF(length(a3), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 780: anchor 3 (END LOOP) matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a3, r3);

  -- The summary ---------------------------------------------------------------
  v_hits := (length(v_new) - length(replace(v_new, a4, ''))) / NULLIF(length(a4), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 780: anchor 4 (RETURN result) matched % times, expected 1', v_hits;
  END IF;
  v_new := replace(v_new, a4, r4);

  EXECUTE v_new;
END $mig$;

COMMENT ON FUNCTION sync_system_roles(text) IS
  'Syncs system-managed roles (ess, manager, dept_head, project_manager) from '
  'employee and project data. Pass p_role_code to limit to one role, or NULL to '
  'sync all. Returns { roleCode: { eligible, inserted, deleted } } per role. '
  'project_manager: named as Reporting Manager on >= 1 active project. '
  'Called by the Role Assignments Sync Now button and auto-triggers on '
  'employee / department_heads / projects changes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Keep it honest: re-sync when a project's manager or active flag moves
-- ─────────────────────────────────────────────────────────────────────────────
-- Mirrors after_dept_head_role_sync on department_heads.
--
-- PERFORMANCE NOTE, stated rather than hidden: sync_system_roles() loops every
-- linked profile, so this is O(profiles) per firing.  That is already true of
-- the employees and department_heads triggers, so this adds a category of cost
-- that exists rather than a new one -- but a bulk UPDATE over the projects table
-- will pay it once per row.  UPDATE OF is narrowed to the two columns that can
-- actually change eligibility so ordinary project edits (name, dates, budget,
-- type) never fire it at all.

CREATE OR REPLACE FUNCTION trg_projects_sync_roles()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM sync_system_roles('project_manager');
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS after_project_manager_role_sync ON projects;

CREATE TRIGGER after_project_manager_role_sync
AFTER INSERT OR DELETE OR UPDATE OF manager_id, active
ON projects
FOR EACH ROW
EXECUTE FUNCTION trg_projects_sync_roles();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Initial population
-- ─────────────────────────────────────────────────────────────────────────────
-- auth.uid() is NULL here, so the function's permission gate lets it through --
-- same path the other sync triggers take.

DO $mig$
DECLARE
  v_result jsonb;
BEGIN
  v_result := sync_system_roles('project_manager');
  RAISE NOTICE 'mig 780: initial project_manager sync -> %', v_result;
END $mig$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $mig$
DECLARE
  v_role_id   uuid;
  v_expected  int;
  v_actual    int;
BEGIN
  SELECT id INTO v_role_id FROM roles WHERE code = 'project_manager';
  IF v_role_id IS NULL THEN
    RAISE EXCEPTION 'mig 780: role project_manager missing after insert';
  END IF;

  -- Every eligible employee with a linked profile should now hold the role.
  SELECT count(*) INTO v_expected
  FROM   profiles pr
  JOIN   employees e ON e.id = pr.employee_id
  WHERE  e.status     = 'Active'
    AND  e.deleted_at IS NULL
    AND  EXISTS (SELECT 1 FROM projects p WHERE p.manager_id = e.id AND p.active = true);

  SELECT count(*) INTO v_actual
  FROM   user_roles ur
  WHERE  ur.role_id           = v_role_id
    AND  ur.assignment_source = 'system';

  IF v_actual <> v_expected THEN
    RAISE EXCEPTION
      'mig 780: expected % system-granted project_manager rows, found %',
      v_expected, v_actual;
  END IF;

  RAISE NOTICE 'mig 780: OK -- % project manager(s) derived from project data', v_actual;
END $mig$;
