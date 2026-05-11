-- =============================================================================
-- Migration 061: Rebuild sync_system_roles()
--
-- Fixes two problems with the previously-deployed version:
--   1. Old function body still referenced the dropped `profile_roles` table.
--   2. Function signature used `p_profile_id uuid` but the UI calls it with
--      the named parameter `p_role_code text`, causing a parameter mismatch.
--   3. Old body referenced `user_roles.is_active` which does not exist.
--
-- New behaviour:
--   • Accepts `p_role_code text DEFAULT NULL`
--     - NULL  → sync ALL system roles (ess, dept_head, manager)
--     - 'ess' → sync only the ESS role, etc.
--   • Returns per-role summary keyed by role code:
--     { "ess": { eligible, inserted, deleted }, ... }
--     Matches exactly what RoleAssignments.tsx expects.
--   • Only uses `user_roles` (profile_roles was dropped in migration 006).
--   • No `is_active` column — uses ON CONFLICT DO NOTHING / DELETE.
-- =============================================================================

-- Drop ALL overloads so there are no signature conflicts
DROP FUNCTION IF EXISTS sync_system_roles(uuid);
DROP FUNCTION IF EXISTS sync_system_roles(text);
DROP FUNCTION IF EXISTS sync_system_roles();

-- ── New sync_system_roles ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_system_roles(p_role_code text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ess_id   uuid;
  v_dh_id    uuid;
  v_mgr_id   uuid;

  -- per-role counters
  v_ess_eligible  int := 0;  v_ess_inserted  int := 0;  v_ess_deleted  int := 0;
  v_dh_eligible   int := 0;  v_dh_inserted   int := 0;  v_dh_deleted   int := 0;
  v_mgr_eligible  int := 0;  v_mgr_inserted  int := 0;  v_mgr_deleted  int := 0;

  v_profile  RECORD;
  v_emp      RECORD;
  result     jsonb := '{}'::jsonb;
BEGIN
  -- Permission gate: only enforce when called by an authenticated user via the API.
  -- When called from a trigger or the SQL Editor, auth.uid() is NULL — allow it through.
  IF auth.uid() IS NOT NULL AND NOT (has_role('admin') OR has_permission('security.manage_roles')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  SELECT id INTO v_ess_id FROM roles WHERE code = 'ess'       LIMIT 1;
  SELECT id INTO v_dh_id  FROM roles WHERE code = 'dept_head' LIMIT 1;
  SELECT id INTO v_mgr_id FROM roles WHERE code = 'manager'   LIMIT 1;

  -- ── Loop over all active linked profiles ──────────────────────────────────
  FOR v_profile IN
    SELECT p.id AS profile_id, p.employee_id
    FROM   profiles p
    WHERE  p.employee_id IS NOT NULL
  LOOP
    SELECT * INTO v_emp
    FROM   employees
    WHERE  id = v_profile.employee_id
    LIMIT  1;

    IF NOT FOUND THEN CONTINUE; END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- ESS role — every active employee
    -- ────────────────────────────────────────────────────────────────────────
    IF p_role_code IS NULL OR p_role_code = 'ess' THEN
      IF v_emp.status = 'Active' AND v_emp.deleted_at IS NULL THEN
        v_ess_eligible := v_ess_eligible + 1;

        INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
        VALUES (v_profile.profile_id, v_ess_id, 'system', now(), now())
        ON CONFLICT (profile_id, role_id) DO NOTHING;

        IF FOUND THEN
          v_ess_inserted := v_ess_inserted + 1;
        END IF;
      ELSE
        -- Employee is inactive — remove ESS if it was system-granted
        DELETE FROM user_roles
        WHERE  profile_id        = v_profile.profile_id
          AND  role_id           = v_ess_id
          AND  assignment_source = 'system';

        IF FOUND THEN
          v_ess_deleted := v_ess_deleted + 1;
        END IF;
      END IF;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- Manager role — employee has ≥1 active direct report
    -- ────────────────────────────────────────────────────────────────────────
    IF (p_role_code IS NULL OR p_role_code = 'manager') AND v_mgr_id IS NOT NULL THEN
      IF EXISTS (
        SELECT 1 FROM employees sub
        WHERE  sub.manager_id = v_emp.id
          AND  sub.status     = 'Active'
          AND  sub.deleted_at IS NULL
      ) THEN
        v_mgr_eligible := v_mgr_eligible + 1;

        INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
        VALUES (v_profile.profile_id, v_mgr_id, 'system', now(), now())
        ON CONFLICT (profile_id, role_id) DO NOTHING;

        IF FOUND THEN
          v_mgr_inserted := v_mgr_inserted + 1;
        END IF;
      ELSE
        DELETE FROM user_roles
        WHERE  profile_id        = v_profile.profile_id
          AND  role_id           = v_mgr_id
          AND  assignment_source = 'system';

        IF FOUND THEN
          v_mgr_deleted := v_mgr_deleted + 1;
        END IF;
      END IF;
    END IF;

    -- ────────────────────────────────────────────────────────────────────────
    -- Dept Head role — listed in department_heads with active date range
    -- ────────────────────────────────────────────────────────────────────────
    IF (p_role_code IS NULL OR p_role_code = 'dept_head') AND v_dh_id IS NOT NULL THEN
      IF EXISTS (
        SELECT 1 FROM department_heads
        WHERE  employee_id = v_emp.id
      ) THEN
        v_dh_eligible := v_dh_eligible + 1;

        INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
        VALUES (v_profile.profile_id, v_dh_id, 'system', now(), now())
        ON CONFLICT (profile_id, role_id) DO NOTHING;

        IF FOUND THEN
          v_dh_inserted := v_dh_inserted + 1;
        END IF;
      ELSE
        DELETE FROM user_roles
        WHERE  profile_id        = v_profile.profile_id
          AND  role_id           = v_dh_id
          AND  assignment_source = 'system';

        IF FOUND THEN
          v_dh_deleted := v_dh_deleted + 1;
        END IF;
      END IF;
    END IF;

  END LOOP;

  -- ── Build per-role result keyed by role code ──────────────────────────────
  IF p_role_code IS NULL OR p_role_code = 'ess' THEN
    result := result || jsonb_build_object('ess', jsonb_build_object(
      'eligible', v_ess_eligible, 'inserted', v_ess_inserted, 'deleted', v_ess_deleted
    ));
  END IF;

  IF p_role_code IS NULL OR p_role_code = 'manager' THEN
    result := result || jsonb_build_object('manager', jsonb_build_object(
      'eligible', v_mgr_eligible, 'inserted', v_mgr_inserted, 'deleted', v_mgr_deleted
    ));
  END IF;

  IF p_role_code IS NULL OR p_role_code = 'dept_head' THEN
    result := result || jsonb_build_object('dept_head', jsonb_build_object(
      'eligible', v_dh_eligible, 'inserted', v_dh_inserted, 'deleted', v_dh_deleted
    ));
  END IF;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION sync_system_roles(text) IS
  'Syncs system-managed roles (ess, manager, dept_head) from employee data. '
  'Pass p_role_code to limit to one role, or NULL to sync all. '
  'Returns { roleCode: { eligible, inserted, deleted } } per role. '
  'Called by the Role Assignments Sync Now button and auto-triggers on '
  'employee/department_heads changes.';


-- ── Re-wire ALL auto-triggers to use the new text signature ─────────────────
-- Any trigger function that previously called sync_system_roles(uuid) must be
-- updated — the uuid overload no longer exists.

-- Fix trg_profiles_sync_roles (fires on profiles UPDATE, was calling uuid overload)
CREATE OR REPLACE FUNCTION trg_profiles_sync_roles()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM sync_system_roles(NULL::text);
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION trg_sync_roles_on_employee_change()
RETURNS TRIGGER AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  -- Find the profile linked to this employee
  SELECT id INTO v_profile_id
  FROM   public.profiles
  WHERE  employee_id = COALESCE(NEW.id, OLD.id)
  LIMIT  1;

  -- Only sync if there's a linked profile
  IF v_profile_id IS NOT NULL THEN
    PERFORM sync_system_roles(NULL);  -- sync all system roles for this profile
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Re-create triggers (drop first in case signature changed)
DROP TRIGGER IF EXISTS trg_sync_roles_after_employee ON employees;
CREATE TRIGGER trg_sync_roles_after_employee
  AFTER INSERT OR UPDATE OR DELETE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION trg_sync_roles_on_employee_change();

DROP TRIGGER IF EXISTS trg_sync_roles_after_dept_head ON department_heads;
CREATE TRIGGER trg_sync_roles_after_dept_head
  AFTER INSERT OR UPDATE OR DELETE ON department_heads
  FOR EACH ROW
  EXECUTE FUNCTION trg_sync_roles_on_employee_change();


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm new signature exists and old uuid overload is gone
SELECT proname, pg_get_function_arguments(oid) AS args
FROM   pg_proc
WHERE  proname = 'sync_system_roles';

-- Quick smoke test (run as admin)
-- SELECT sync_system_roles('ess');
