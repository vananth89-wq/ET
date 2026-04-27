-- =============================================================================
-- Migration: Sync user_roles → profile_roles (data-driven, no hardcoding)
--
-- Problem:
--   user_roles   = what the Role Assignments UI manages (named roles)
--   profile_roles = what Postgres RLS enforces via has_role()
--   These were never connected, so UI assignments had no DB access effect.
--
-- Approach:
--   Add roles.mapped_role_type column — the mapping lives in the data,
--   not in a hardcoded function. New custom roles just need this column set.
--
-- Steps:
--   1. Add 'hr' to role_type enum
--   2. Add mapped_role_type column to roles table
--   3. Populate mapped_role_type for all existing roles
--   4. Trigger: user_roles INSERT/DELETE → sync profile_roles automatically
--   5. Backfill existing user_roles rows
-- =============================================================================


-- ── Step 1: Extend role_type enum ────────────────────────────────────────────

ALTER TYPE role_type ADD VALUE IF NOT EXISTS 'hr';


-- ── Step 2: Add mapped_role_type to roles ────────────────────────────────────
-- NULL means "no RLS effect" (e.g. a reporting-only custom role).
-- Set this when creating new custom roles via the UI or SQL.

ALTER TABLE roles
  ADD COLUMN IF NOT EXISTS mapped_role_type role_type NULL;

COMMENT ON COLUMN roles.mapped_role_type IS
  'Maps this named role to the role_type enum used by RLS has_role() checks.
   NULL = no database-level access change (UI-only role).
   Set on role creation — no code changes needed when adding new roles.';


-- ── Step 3: Populate mapped_role_type for existing roles ─────────────────────
-- Uses roles.code to seed initial values. After this, the column is the
-- source of truth — roles.code is just a display identifier.

UPDATE roles SET mapped_role_type = 'admin'::role_type
  WHERE code IN ('admin');

UPDATE roles SET mapped_role_type = 'finance'::role_type
  WHERE code IN ('finance');

UPDATE roles SET mapped_role_type = 'hr'::role_type
  WHERE code IN ('hr');

UPDATE roles SET mapped_role_type = 'manager'::role_type
  WHERE code IN ('manager', 'dept_head', 'mss');

UPDATE roles SET mapped_role_type = 'employee'::role_type
  WHERE code IN ('employee', 'ess');

-- Custom roles with no RLS mapping get NULL (already the default).


-- ── Step 4a: Trigger function ─────────────────────────────────────────────────
-- Reads roles.mapped_role_type — no CASE statement, no hardcoding.
-- Works automatically for any future role as long as mapped_role_type is set.

CREATE OR REPLACE FUNCTION sync_user_roles_to_profile_roles()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role_type  role_type;
  v_still_has  boolean;
BEGIN

  IF TG_OP = 'INSERT' THEN
    -- Look up the mapped type directly from the roles table
    SELECT mapped_role_type INTO v_role_type
    FROM roles WHERE id = NEW.role_id;

    IF v_role_type IS NOT NULL THEN
      INSERT INTO profile_roles (profile_id, role, assigned_by)
      VALUES (NEW.profile_id, v_role_type, NEW.assigned_by)
      ON CONFLICT (profile_id, role) DO NOTHING;
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    SELECT mapped_role_type INTO v_role_type
    FROM roles WHERE id = OLD.role_id;

    IF v_role_type IS NOT NULL THEN
      -- Only remove from profile_roles if no other user_roles row for this
      -- profile still maps to the same role_type (e.g. dept_head + mss both
      -- map to 'manager' — removing one should not strip manager access).
      SELECT EXISTS (
        SELECT 1
        FROM user_roles ur
        JOIN roles r ON r.id = ur.role_id
        WHERE ur.profile_id      = OLD.profile_id
          AND ur.id             <> OLD.id
          AND r.mapped_role_type = v_role_type
      ) INTO v_still_has;

      IF NOT v_still_has THEN
        DELETE FROM profile_roles
        WHERE profile_id = OLD.profile_id
          AND role       = v_role_type;
      END IF;
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


-- ── Step 4b: Attach trigger ───────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_sync_user_roles_to_profile_roles ON user_roles;

CREATE TRIGGER trg_sync_user_roles_to_profile_roles
  AFTER INSERT OR DELETE ON user_roles
  FOR EACH ROW
  EXECUTE FUNCTION sync_user_roles_to_profile_roles();


-- ── Step 5: Backfill existing user_roles → profile_roles ─────────────────────

INSERT INTO profile_roles (profile_id, role, assigned_by)
SELECT
  ur.profile_id,
  r.mapped_role_type,
  ur.assigned_by
FROM user_roles ur
JOIN roles r ON r.id = ur.role_id
WHERE r.mapped_role_type IS NOT NULL
ON CONFLICT (profile_id, role) DO NOTHING;


-- ── Step 6: Verification ─────────────────────────────────────────────────────

SELECT
  e.name                  AS employee,
  r.code                  AS role_code,
  r.mapped_role_type      AS maps_to,
  pr.role IS NOT NULL     AS synced_to_profile_roles
FROM user_roles ur
JOIN roles      r  ON r.id  = ur.role_id
JOIN profiles   p  ON p.id  = ur.profile_id
LEFT JOIN employees e ON e.id = p.employee_id
LEFT JOIN profile_roles pr
  ON  pr.profile_id = ur.profile_id
  AND pr.role       = r.mapped_role_type
WHERE r.mapped_role_type IS NOT NULL
ORDER BY e.name, r.code;
