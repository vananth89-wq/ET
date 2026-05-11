-- =============================================================================
-- Migration 148: Sync profiles.is_active with employees.status
--
-- GAP IDENTIFIED
-- ──────────────
-- Migration 059 (revoke_ess_on_deactivation) fires when employees.status
-- flips to 'Inactive' and removes the ESS user_role. However it never sets
-- profiles.is_active = false. The flag stays true forever, meaning:
--
--   • Workflow queries filtering AND p.is_active = true could still surface
--     deactivated employees as valid approvers if they hold a non-ESS role.
--   • Any frontend/API check against profiles.is_active incorrectly shows
--     them as active.
--
-- Reactivation (status: Inactive → Active) was also unhandled — profiles
-- remained is_active = false (if ever manually set) and no ESS role was
-- re-granted automatically.
--
-- FIX
-- ───
-- Replace revoke_ess_on_deactivation with a broader trigger function
-- sync_profile_on_employee_status() that handles both transitions:
--
--   Inactive path  (Active/Draft/Incomplete → Inactive):
--     1. SET profiles.is_active = false
--     2. DELETE all user_roles for that profile  (not just ESS)
--
--   Active path  (Inactive → Active):
--     1. SET profiles.is_active = true
--     2. Re-grant ESS role  (same as reconcile_employee_profiles does)
--
-- WHY DELETE ALL ROLES ON DEACTIVATION
-- ──────────────────────────────────────
-- Removing only the ESS role left non-ESS roles (manager, hr, etc.) intact,
-- meaning a deactivated employee with an admin role could still pass
-- user_can() checks. Removing all roles ensures a clean permission state.
-- On reactivation only ESS is re-granted — any elevated roles must be
-- re-assigned explicitly by an admin, which is the correct security posture.
--
-- BACKWARD COMPATIBILITY
-- ──────────────────────
-- The old trigger trg_revoke_ess_on_deactivation is dropped and replaced
-- by trg_sync_profile_on_employee_status on the same table/event.
-- The old function is also dropped after the trigger is replaced.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New trigger function
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_profile_on_employee_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
  v_ess_role   uuid;
BEGIN
  -- No-op if status didn't change
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- Resolve the linked profile
  SELECT id INTO v_profile_id
  FROM   profiles
  WHERE  employee_id = NEW.id
  LIMIT  1;

  IF v_profile_id IS NULL THEN
    RETURN NEW;  -- no linked profile yet (e.g. Draft employee, invite pending)
  END IF;

  -- ── Deactivation: any status → Inactive ──────────────────────────────────
  IF NEW.status = 'Inactive' AND OLD.status IS DISTINCT FROM 'Inactive' THEN

    -- 1. Mark profile inactive — blocks login and removes from workflow pools
    UPDATE profiles
    SET    is_active  = false,
           updated_at = now()
    WHERE  id = v_profile_id;

    -- 2. Revoke ALL roles — clean permission state; re-assignment required
    --    on reactivation for any elevated roles
    DELETE FROM user_roles
    WHERE  profile_id = v_profile_id;

  END IF;

  -- ── Reactivation: Inactive → Active ──────────────────────────────────────
  IF NEW.status = 'Active' AND OLD.status = 'Inactive' THEN

    -- 1. Re-enable profile
    UPDATE profiles
    SET    is_active  = true,
           updated_at = now()
    WHERE  id = v_profile_id;

    -- 2. Re-grant ESS role only — elevated roles must be explicitly re-assigned
    SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

    IF v_ess_role IS NOT NULL THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
      VALUES (v_profile_id, v_ess_role, 'system_reactivation', now(), now())
      ON CONFLICT (profile_id, role_id) DO NOTHING;
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION sync_profile_on_employee_status() IS
  'Fires AFTER UPDATE on employees when status changes. '
  'Deactivation (→ Inactive): sets profiles.is_active=false, deletes ALL user_roles. '
  'Reactivation (Inactive → Active): sets profiles.is_active=true, re-grants ESS role only. '
  'Elevated roles (manager, hr, etc.) must be re-assigned explicitly after reactivation. '
  'Supersedes revoke_ess_on_deactivation (migration 059).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Replace the old trigger
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_revoke_ess_on_deactivation      ON employees;
DROP TRIGGER IF EXISTS trg_sync_profile_on_employee_status ON employees;

CREATE TRIGGER trg_sync_profile_on_employee_status
  AFTER UPDATE ON employees
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION sync_profile_on_employee_status();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Drop old function (no longer referenced)
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS revoke_ess_on_deactivation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Backfill — fix any employees already Inactive whose profile is still active
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE profiles p
SET    is_active  = false,
       updated_at = now()
FROM   employees e
WHERE  e.id         = p.employee_id
  AND  e.status     = 'Inactive'
  AND  p.is_active  = true;

-- Remove all roles for profiles that are now inactive
DELETE FROM user_roles ur
USING  profiles p
WHERE  ur.profile_id = p.id
  AND  p.is_active   = false;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm new trigger exists, old one is gone
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgrelid = 'employees'::regclass
  AND  tgname IN (
    'trg_sync_profile_on_employee_status',
    'trg_revoke_ess_on_deactivation'
  );

-- Confirm no Inactive employee has an active profile
SELECT COUNT(*) AS gap_count
FROM   employees e
JOIN   profiles  p ON p.employee_id = e.id
WHERE  e.status    = 'Inactive'
  AND  p.is_active = true;

-- =============================================================================
-- END OF MIGRATION 148
--
-- BEHAVIOUR SUMMARY
-- ─────────────────
-- Employee deactivated  → profiles.is_active = false, all roles deleted
-- Employee reactivated  → profiles.is_active = true,  ESS role re-granted
-- Elevated roles after reactivation must be re-assigned manually by an admin
-- =============================================================================
