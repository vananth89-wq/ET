-- =============================================================================
-- Migration 092: RBP Phase 4 — Permission Sets
--
-- DESIGN
-- ══════
-- Instead of assigning permissions directly to roles, admins create named
-- "Permission Sets" that bundle a set of module/action grants.  Each set is
-- then ASSIGNED to a role + target population via permission_set_assignments.
--
-- This allows:
--   • Multiple sets for the same role with different target populations
--     e.g. "Manager – Direct Team" (Direct L1) and "Manager – All" (Everyone)
--   • Reuse of a set across roles (same access profile, different population)
--   • Fine-grained audit: each set has a name and history
--
-- Tables
-- ──────
-- permission_sets
--   Named, reusable access profiles created by admins.
--
-- permission_set_items
--   Junction: which RBP permissions (action IS NOT NULL) belong to a set.
--   One row per (set, permission) pair.
--
-- permission_set_assignments
--   Junction: which role gets a set, and for which target population.
--   target_group_id = NULL  → Admin-module permissions (no scoping)
--   target_group_id = <id>  → EV-module permissions scoped to that group
--
-- Future (Phase 5)
-- ────────────────
-- user_can() will be updated to evaluate via permission_sets instead of the
-- legacy role_permissions direct lookup.  For now this table drives only the
-- Permission Matrix UI.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. permission_sets
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS permission_sets (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  description text,
  created_by  uuid        REFERENCES profiles (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  permission_sets             IS 'Named permission profiles. Each set bundles module/action grants that can be assigned to a role + target population.';
COMMENT ON COLUMN permission_sets.name        IS 'Admin-chosen display name, e.g. "Manager – Direct Team".';
COMMENT ON COLUMN permission_sets.description IS 'Optional free-text description of this permission set''s purpose.';

CREATE INDEX IF NOT EXISTS idx_psets_created_at ON permission_sets (created_at DESC);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. permission_set_items
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS permission_set_items (
  permission_set_id  uuid NOT NULL REFERENCES permission_sets (id)  ON DELETE CASCADE,
  permission_id      uuid NOT NULL REFERENCES permissions     (id)  ON DELETE CASCADE,
  PRIMARY KEY (permission_set_id, permission_id)
);

COMMENT ON TABLE permission_set_items IS
  'Which permissions (RBP action-based only) belong to a permission set. '
  'Populated and maintained by the Permission Matrix UI.';

CREATE INDEX IF NOT EXISTS idx_psi_perm ON permission_set_items (permission_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. permission_set_assignments
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS permission_set_assignments (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  permission_set_id uuid        NOT NULL REFERENCES permission_sets (id) ON DELETE CASCADE,
  role_id           uuid        NOT NULL REFERENCES roles            (id) ON DELETE CASCADE,
  target_group_id   uuid                 REFERENCES target_groups   (id) ON DELETE RESTRICT,
  created_at        timestamptz NOT NULL DEFAULT now(),

  -- One role can be assigned to the same set only once per target group
  UNIQUE (permission_set_id, role_id, target_group_id)
);

COMMENT ON TABLE  permission_set_assignments                    IS 'Links a permission set to a role and optional target population.';
COMMENT ON COLUMN permission_set_assignments.target_group_id   IS 'NULL = Admin-module grant (no scoping). Set = EV-module grant restricted to that target group members.';

CREATE INDEX IF NOT EXISTS idx_psa_role    ON permission_set_assignments (role_id);
CREATE INDEX IF NOT EXISTS idx_psa_set     ON permission_set_assignments (permission_set_id);
CREATE INDEX IF NOT EXISTS idx_psa_tg      ON permission_set_assignments (target_group_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. updated_at trigger for permission_sets
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION touch_permission_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pset_updated_at ON permission_sets;
CREATE TRIGGER trg_pset_updated_at
  BEFORE UPDATE ON permission_sets
  FOR EACH ROW EXECUTE FUNCTION touch_permission_set_updated_at();


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RLS
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE permission_sets            ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_set_items       ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_set_assignments ENABLE ROW LEVEL SECURITY;

-- permission_sets: admin full control, authenticated read
DROP POLICY IF EXISTS pset_select ON permission_sets;
DROP POLICY IF EXISTS pset_insert ON permission_sets;
DROP POLICY IF EXISTS pset_update ON permission_sets;
DROP POLICY IF EXISTS pset_delete ON permission_sets;
CREATE POLICY pset_select ON permission_sets FOR SELECT USING (true);
CREATE POLICY pset_insert ON permission_sets FOR INSERT WITH CHECK (has_role('admin'));
CREATE POLICY pset_update ON permission_sets FOR UPDATE USING (has_role('admin'));
CREATE POLICY pset_delete ON permission_sets FOR DELETE USING (has_role('admin'));

-- permission_set_items: admin full control, authenticated read
DROP POLICY IF EXISTS psi_select ON permission_set_items;
DROP POLICY IF EXISTS psi_insert ON permission_set_items;
DROP POLICY IF EXISTS psi_delete ON permission_set_items;
CREATE POLICY psi_select ON permission_set_items FOR SELECT USING (true);
CREATE POLICY psi_insert ON permission_set_items FOR INSERT WITH CHECK (has_role('admin'));
CREATE POLICY psi_delete ON permission_set_items FOR DELETE USING (has_role('admin'));

-- permission_set_assignments: admin full control, authenticated read
DROP POLICY IF EXISTS psa_select ON permission_set_assignments;
DROP POLICY IF EXISTS psa_insert ON permission_set_assignments;
DROP POLICY IF EXISTS psa_update ON permission_set_assignments;
DROP POLICY IF EXISTS psa_delete ON permission_set_assignments;
CREATE POLICY psa_select ON permission_set_assignments FOR SELECT USING (true);
CREATE POLICY psa_insert ON permission_set_assignments FOR INSERT WITH CHECK (has_role('admin'));
CREATE POLICY psa_update ON permission_set_assignments FOR UPDATE USING (has_role('admin'));
CREATE POLICY psa_delete ON permission_set_assignments FOR DELETE USING (has_role('admin'));


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'permission_sets table' AS check,
  column_name, data_type
FROM information_schema.columns
WHERE table_name = 'permission_sets'
ORDER BY ordinal_position;

SELECT 'permission_set_assignments table' AS check,
  column_name, data_type
FROM information_schema.columns
WHERE table_name = 'permission_set_assignments'
ORDER BY ordinal_position;

-- =============================================================================
-- END OF MIGRATION 20260501092_permission_sets_schema.sql
-- =============================================================================
