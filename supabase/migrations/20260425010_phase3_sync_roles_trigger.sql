-- =============================================================================
-- Phase 3: Auto-trigger sync_system_roles()
--
-- Problem:
--   sync_system_roles() currently must be called manually by an admin after
--   any employee data change. This means role assignments can drift out of
--   sync if an admin forgets to run it.
--
-- Solution:
--   Postgres triggers on three tables automatically call sync_system_roles()
--   for the affected profile whenever data changes that would affect role
--   assignments.
--
-- Trigger sources and why each matters:
--
--   employees (INSERT / UPDATE status|deleted_at)
--     → A new employee record should immediately get ESS once linked to a
--       profile. Status going Inactive / deleted_at being set should revoke ESS.
--
--   department_heads (INSERT / UPDATE / DELETE)
--     → Adding a dept head row should grant dept_head role.
--       Setting to_date (marking end of tenure) should revoke dept_head role.
--       Deleting the row entirely should also revoke.
--
--   profiles (UPDATE employee_id)
--     → When an admin links an existing user account to an employee record
--       (employee_id NULL → value), ESS + dept_head should be assigned
--       immediately without requiring a manual sync.
--
-- Additionally, sync_system_roles() is improved to check employees.status
-- so that Inactive employees do NOT receive ESS — matching the business intent
-- ("every *active* employee gets ESS").
-- =============================================================================


-- ── Step 1: Improve sync_system_roles() — respect employees.status ────────────
--
-- Previous version only checked profiles.is_active.
-- Now also requires employees.status = 'Active' before granting ESS.
-- dept_head logic is unchanged (department_heads.to_date drives it).

CREATE OR REPLACE FUNCTION sync_system_roles(p_profile_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile   RECORD;
  v_emp       RECORD;
  v_ess_id    uuid;
  v_dh_id     uuid;
  v_inserted  integer := 0;
  v_removed   integer := 0;
BEGIN
  SELECT id INTO v_ess_id FROM roles WHERE code = 'ess';
  SELECT id INTO v_dh_id  FROM roles WHERE code = 'dept_head';

  FOR v_profile IN
    SELECT p.id, p.employee_id
    FROM   profiles p
    WHERE  (p_profile_id IS NULL OR p.id = p_profile_id)
      AND  p.is_active = true
  LOOP
    IF v_profile.employee_id IS NULL THEN CONTINUE; END IF;

    SELECT * INTO v_emp
    FROM employees
    WHERE id = v_profile.employee_id
      AND deleted_at IS NULL;            -- skip soft-deleted employees

    IF NOT FOUND THEN
      -- Employee was soft-deleted or not found — revoke ESS
      UPDATE user_roles
      SET    is_active = false, updated_at = now()
      WHERE  profile_id        = v_profile.id
        AND  role_id           = v_ess_id
        AND  assignment_source = 'system'
        AND  is_active         = true;
      GET DIAGNOSTICS v_removed = ROW_COUNT;
      CONTINUE;
    END IF;

    -- ── ESS: only for employees with status = 'Active' ───────────────────────
    IF v_emp.status = 'Active' THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_ess_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true, updated_at = now();
      v_inserted := v_inserted + 1;
    ELSE
      -- Inactive / Draft / Incomplete employee — revoke ESS if present
      UPDATE user_roles
      SET    is_active = false, updated_at = now()
      WHERE  profile_id        = v_profile.id
        AND  role_id           = v_ess_id
        AND  assignment_source = 'system'
        AND  is_active         = true;
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

    -- ── Department Head: driven by department_heads table ────────────────────
    IF EXISTS (
      SELECT 1 FROM department_heads
      WHERE employee_id = v_emp.id
        AND (to_date IS NULL OR to_date >= CURRENT_DATE)
    ) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_dh_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true, updated_at = now();
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles
      SET    is_active = false, updated_at = now()
      WHERE  profile_id        = v_profile.id
        AND  role_id           = v_dh_id
        AND  assignment_source = 'system'
        AND  is_active         = true;
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('synced', v_inserted, 'revoked', v_removed);
END;
$$;


-- ── Step 2: Trigger function for employees table ──────────────────────────────
--
-- Called after INSERT or UPDATE of status / deleted_at on employees.
-- Looks up the profile linked to this employee and syncs their system roles.
-- No-op if no profile is linked yet (profile.employee_id will trigger its own
-- sync when it is linked — see Step 4).

CREATE OR REPLACE FUNCTION trg_employees_sync_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  -- Find the profile linked to this employee record
  SELECT id INTO v_profile_id
  FROM   profiles
  WHERE  employee_id = NEW.id
    AND  is_active   = true
  LIMIT 1;

  -- No linked profile yet — nothing to sync
  IF v_profile_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Run the sync for this specific profile
  PERFORM sync_system_roles(v_profile_id);

  RETURN NEW;
END;
$$;

-- Trigger: fire after INSERT (new employee) or UPDATE of the columns that
-- affect role eligibility (status change, soft-delete).
-- UPDATE trigger is column-specific to avoid running on every tiny edit.

DROP TRIGGER IF EXISTS after_employee_role_sync ON employees;

CREATE TRIGGER after_employee_role_sync
AFTER INSERT OR UPDATE OF status, deleted_at
ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_employees_sync_roles();


-- ── Step 3: Trigger function for department_heads table ──────────────────────
--
-- Called after INSERT, UPDATE, or DELETE on department_heads.
-- Syncs roles for the employee affected by the change.
-- On UPDATE that changes employee_id (rare but possible), syncs BOTH the
-- old and new employee.

CREATE OR REPLACE FUNCTION trg_department_heads_sync_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id     uuid;
  v_profile_id uuid;
BEGIN
  -- Determine the affected employee UUID
  -- For DELETE we use OLD, for INSERT/UPDATE we use NEW
  v_emp_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.employee_id ELSE NEW.employee_id END;

  -- Sync the primary affected employee
  SELECT id INTO v_profile_id
  FROM   profiles
  WHERE  employee_id = v_emp_id
    AND  is_active   = true
  LIMIT 1;

  IF v_profile_id IS NOT NULL THEN
    PERFORM sync_system_roles(v_profile_id);
  END IF;

  -- On UPDATE: if the employee changed (unusual but guard it), also sync old one
  IF TG_OP = 'UPDATE' AND OLD.employee_id IS DISTINCT FROM NEW.employee_id THEN
    SELECT id INTO v_profile_id
    FROM   profiles
    WHERE  employee_id = OLD.employee_id
      AND  is_active   = true
    LIMIT 1;

    IF v_profile_id IS NOT NULL THEN
      PERFORM sync_system_roles(v_profile_id);
    END IF;
  END IF;

  -- Return appropriate row for INSERT/UPDATE vs DELETE
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS after_dept_head_role_sync ON department_heads;

CREATE TRIGGER after_dept_head_role_sync
AFTER INSERT OR UPDATE OR DELETE
ON department_heads
FOR EACH ROW
EXECUTE FUNCTION trg_department_heads_sync_roles();


-- ── Step 4: Trigger function for profiles table ───────────────────────────────
--
-- Called after UPDATE when employee_id is being linked to a profile.
-- Scenario: admin creates an employee record, then the employee signs up
-- and admin links their auth account to the employee record.
-- The moment employee_id is set, ESS (and dept_head if applicable) should
-- be assigned immediately.
--
-- Only fires when:
--   OLD.employee_id IS NULL  AND  NEW.employee_id IS NOT NULL  (first link)
--   OLD.employee_id != NEW.employee_id                         (re-link)

CREATE OR REPLACE FUNCTION trg_profiles_sync_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only act when the employee_id is being set or changed
  IF NEW.employee_id IS NOT NULL
     AND (OLD.employee_id IS NULL OR OLD.employee_id IS DISTINCT FROM NEW.employee_id)
  THEN
    PERFORM sync_system_roles(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS after_profile_employee_link ON profiles;

CREATE TRIGGER after_profile_employee_link
AFTER UPDATE OF employee_id
ON profiles
FOR EACH ROW
EXECUTE FUNCTION trg_profiles_sync_roles();


-- ── Step 5: Backfill — run sync for all active profiles now ──────────────────
--
-- Ensures any existing profiles that were never manually synced are brought
-- up to date before the triggers take over going forward.
-- This is safe to run repeatedly (all operations are idempotent).

SELECT sync_system_roles(NULL::uuid);  -- explicit cast disambiguates the two overloads


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm triggers exist on the right tables
SELECT
  trigger_name,
  event_object_table  AS "table",
  event_manipulation  AS "event",
  action_timing       AS "timing"
FROM information_schema.triggers
WHERE trigger_name IN (
  'after_employee_role_sync',
  'after_dept_head_role_sync',
  'after_profile_employee_link'
)
ORDER BY event_object_table, trigger_name, event_manipulation;

-- Confirm no active profiles are missing their ESS role
-- (should return 0 rows if backfill + triggers are working)
SELECT
  p.id          AS profile_id,
  u.email,
  e.name        AS employee_name,
  e.status      AS emp_status
FROM profiles p
JOIN auth.users u  ON u.id  = p.id
JOIN employees e   ON e.id  = p.employee_id
LEFT JOIN user_roles ur
  ON  ur.profile_id = p.id
  AND ur.role_id    = (SELECT id FROM roles WHERE code = 'ess')
  AND ur.is_active  = true
WHERE p.is_active   = true
  AND e.status      = 'Active'
  AND e.deleted_at  IS NULL
  AND ur.profile_id IS NULL   -- missing ESS
ORDER BY u.email;
