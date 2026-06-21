-- =============================================================================
-- Migration 521 — Fix system_reactivation assignment_source CHECK constraint
--
-- ROOT CAUSE
-- ──────────
-- sync_profile_on_employee_status() (mig 148, extended in mig 362) inserts
-- ESS user_roles with assignment_source = 'system_reactivation' on the
-- Inactive → Active path.  However mig 062 only widened the CHECK constraint
-- to include:
--   'manual', 'system', 'invite', 'auto', 'reconcile', 'backfill', 'sync_job'
--
-- 'system_reactivation' was never added.  Every time an Active employee was
-- previously deactivated (Inactive) and then reactivated (Active), the trigger
-- attempted to INSERT with the illegal value → CHECK violation → INSERT aborted
-- → the employee has status=Active in employees but ZERO user_roles rows →
-- get_my_permissions() returns {} → every can() call returns false →
-- ProtectedRoute shows "Access Denied" for their own profile page.
--
-- The employees table row shows status='Active' (the trigger still returns NEW
-- so the status UPDATE commits), but the user_roles INSERT is silently lost
-- inside the trigger body — no user-visible error, just missing permissions.
--
-- AFFECTED USERS
-- ──────────────
-- Any employee whose status has ever gone Inactive → Active since mig 148 was
-- applied.  They will appear Active in Role Assignments (employee.status = Active)
-- but have no user_roles row → completely locked out.
--
-- FIX
-- ───
-- 1. Add 'system_reactivation' to the user_roles_assignment_source_check constraint.
-- 2. Backfill: insert ESS user_roles for every Active employee with a linked
--    profile who currently has no user_roles row at all (or only inactive rows).
-- 3. This single migration fixes both the constraint and the missing data.
--
-- SAFE TO RE-RUN: all INSERTs use ON CONFLICT DO UPDATE to be idempotent.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Widen the CHECK constraint to include 'system_reactivation'
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE user_roles
  DROP CONSTRAINT IF EXISTS user_roles_assignment_source_check;

ALTER TABLE user_roles
  ADD CONSTRAINT user_roles_assignment_source_check
  CHECK (assignment_source IN (
    'manual',
    'system',
    'invite',
    'auto',
    'reconcile',
    'backfill',
    'sync_job',
    'system_reactivation'   -- ← added: used by sync_profile_on_employee_status()
  ));

COMMENT ON COLUMN user_roles.assignment_source IS
  'How the role was granted: '
  'manual = admin assigned it in Role Assignments UI. '
  'system = auto-sync via sync_system_roles(). '
  'invite = granted at Activate Employee time. '
  'auto = granted by handle_new_user() trigger on first sign-in. '
  'reconcile = back-filled by reconcile_employee_profiles(). '
  'backfill = granted by backfill_ess_for_active_employees(). '
  'sync_job = granted by sync_employee_ess() pg-cron job. '
  'system_reactivation = re-granted by sync_profile_on_employee_status() on Inactive→Active.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill: restore ESS for Active employees missing their user_roles row
--
--    Targets: employees.status = 'Active' AND deleted_at IS NULL
--             WITH a linked profile (profiles.employee_id = employees.id)
--             BUT with no active user_roles row for the ESS role.
--
--    Uses ON CONFLICT DO UPDATE SET is_active = true to also heal any rows
--    that somehow have is_active = false.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_ess_role uuid;
  v_count    int := 0;
BEGIN
  SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

  IF v_ess_role IS NULL THEN
    RAISE EXCEPTION 'ESS role not found — cannot backfill user_roles';
  END IF;

  -- Insert ESS for every Active employee whose profile has no active ESS row
  WITH missing AS (
    SELECT p.id AS profile_id
    FROM   employees e
    JOIN   profiles  p ON p.employee_id = e.id
    WHERE  e.status     = 'Active'
      AND  e.deleted_at IS NULL
      AND  NOT EXISTS (
        SELECT 1 FROM user_roles ur
        WHERE  ur.profile_id = p.id
          AND  ur.role_id    = v_ess_role
          AND  ur.is_active  = true
      )
  )
  INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
  SELECT profile_id, v_ess_role, 'system_reactivation', now(), now()
  FROM   missing
  ON CONFLICT (profile_id, role_id)
    DO UPDATE SET is_active  = true,
                  updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'Mig 521: backfilled ESS user_roles for % profile(s).', v_count;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Constraint includes system_reactivation
  ASSERT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conname = 'user_roles_assignment_source_check'
      AND  pg_get_constraintdef(oid) LIKE '%system_reactivation%'
  ), 'system_reactivation missing from user_roles_assignment_source_check';

  -- No Active employee with a profile is missing an active ESS row
  ASSERT NOT EXISTS (
    SELECT 1
    FROM   employees e
    JOIN   profiles  p ON p.employee_id = e.id
    CROSS  JOIN (SELECT id FROM roles WHERE code = 'ess') r
    WHERE  e.status     = 'Active'
      AND  e.deleted_at IS NULL
      AND  NOT EXISTS (
        SELECT 1 FROM user_roles ur
        WHERE  ur.profile_id = p.id
          AND  ur.role_id    = r.id
          AND  ur.is_active  = true
      )
  ), 'Active employees with profiles still have no active ESS user_roles row';

  RAISE NOTICE 'Mig 521 verification passed.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 521
-- =============================================================================
