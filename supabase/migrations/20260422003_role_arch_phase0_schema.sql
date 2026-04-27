-- =============================================================================
-- Role Architecture — Phase 0: Schema Additions
--
-- Adds columns to roles and user_roles.
-- Purely additive — zero downtime, fully backward compatible.
-- =============================================================================


-- ── roles: add active, sort_order, editable ───────────────────────────────────

ALTER TABLE roles
  ADD COLUMN IF NOT EXISTS active      BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS sort_order  INTEGER NOT NULL DEFAULT 99,
  ADD COLUMN IF NOT EXISTS editable    BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN roles.active     IS 'Soft-disable a role without deleting it.';
COMMENT ON COLUMN roles.sort_order IS 'UI display order. Lower = higher in list.';
COMMENT ON COLUMN roles.editable   IS 'false = UI cannot edit members or permissions (enforced client-side + by is_system).';

-- Set sensible defaults for existing system roles
UPDATE roles SET editable = false WHERE is_system = true;
UPDATE roles SET sort_order = CASE code
  WHEN 'admin'     THEN 1
  WHEN 'finance'   THEN 2
  WHEN 'hr'        THEN 3
  WHEN 'manager'   THEN 4
  WHEN 'dept_head' THEN 5
  WHEN 'mss'       THEN 6
  WHEN 'ess'       THEN 7
  ELSE 99
END;


-- ── user_roles: add is_active, expires_at, updated_at, assignment_source ──────

ALTER TABLE user_roles
  ADD COLUMN IF NOT EXISTS is_active         BOOLEAN     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS expires_at        TIMESTAMPTZ          DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS assignment_source TEXT        NOT NULL DEFAULT 'manual'
    CHECK (assignment_source IN ('manual', 'system'));

COMMENT ON COLUMN user_roles.is_active         IS 'Soft-disable without deleting. Audit trail preserved.';
COMMENT ON COLUMN user_roles.expires_at        IS 'NULL = permanent. Set for contractors or temp access.';
COMMENT ON COLUMN user_roles.updated_at        IS 'Standard audit column.';
COMMENT ON COLUMN user_roles.assignment_source IS 'manual = admin set it. system = auto-sync (sync_system_roles).';

-- Mark existing system-sync rows (ESS, MSS, dept_head) as source=system
-- Best effort: any role with is_system=true was likely auto-assigned
UPDATE user_roles ur
SET assignment_source = 'system'
FROM roles r
WHERE r.id = ur.role_id AND r.is_system = true;

-- updated_at trigger for user_roles
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_user_roles_updated_at ON user_roles;
CREATE TRIGGER trg_user_roles_updated_at
  BEFORE UPDATE ON user_roles
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ── Performance indexes ───────────────────────────────────────────────────────

-- Primary lookup used by has_role() — covers 99% of RLS evaluations.
-- Only filters on is_active (a static boolean — safe for a partial index).
-- The expires_at > now() check is handled at query time inside has_role(),
-- which cannot appear here because NOW() is STABLE, not IMMUTABLE.
CREATE INDEX IF NOT EXISTS idx_user_roles_profile_active
  ON user_roles (profile_id, role_id)
  WHERE is_active = true;

-- Role code lookup (has_role joins here)
-- roles.code already has a UNIQUE index — no additional index needed.

-- Covering index for role listing in UI
CREATE INDEX IF NOT EXISTS idx_user_roles_profile_id
  ON user_roles (profile_id)
  WHERE is_active = true;
