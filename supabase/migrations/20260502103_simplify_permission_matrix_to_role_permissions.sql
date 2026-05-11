-- =============================================================================
-- Migration 103: Simplify Permission Matrix — write directly to role_permissions
--
-- BACKGROUND
-- ──────────
-- The Permission Matrix UI (migration 092) saved to:
--   permission_sets → permission_set_items → permission_set_assignments
--
-- That hierarchy was never connected to role_permissions, so grants had zero
-- effect on user_can() (RLS) or get_my_permissions() (UI gates).
--
-- SOLUTION
-- ────────
-- The Permission Matrix UI is redesigned to write directly to role_permissions
-- (with target_group_id on every row so get_target_population() keeps working).
-- The permission_sets tables are RETAINED but no longer used by the matrix UI.
--
-- This migration:
--   1. Adds a UNIQUE constraint on (role_id, permission_id) to prevent duplicates.
--   2. Backfills role_permissions from the existing permission_set data so all
--      previously configured matrix grants become live immediately.
--
-- After this migration:
--   • user_can()             reads role_permissions  → RLS enforcement works ✓
--   • get_my_permissions()   reads role_permissions  → UI gates work ✓
--   • get_target_population() reads role_permissions.target_group_id → scoping works ✓
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Remove duplicate (role_id, permission_id) rows before adding constraint
-- ─────────────────────────────────────────────────────────────────────────────

-- role_permissions has no surrogate id — use ctid (Postgres internal row pointer)
DELETE FROM role_permissions
WHERE ctid NOT IN (
  SELECT MIN(ctid)
  FROM   role_permissions
  GROUP BY role_id, permission_id
);


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Add UNIQUE constraint
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE role_permissions
  DROP CONSTRAINT IF EXISTS uq_role_permissions_role_perm;

ALTER TABLE role_permissions
  ADD CONSTRAINT uq_role_permissions_role_perm
  UNIQUE (role_id, permission_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Backfill role_permissions from permission_set_assignments + items
--
-- For each existing matrix assignment:
--   permission_set_assignments.role_id            → role_permissions.role_id
--   permission_set_items.permission_id            → role_permissions.permission_id
--   permission_set_assignments.target_group_id    → role_permissions.target_group_id
--
-- ON CONFLICT: if a direct legacy row already exists for this (role, permission),
-- only update target_group_id if it was NULL (don't override explicit legacy grants).
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id, target_group_id)
SELECT DISTINCT
  psa.role_id,
  psi.permission_id,
  psa.target_group_id
FROM  permission_set_assignments psa
JOIN  permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
WHERE psa.role_id IS NOT NULL
ON CONFLICT (role_id, permission_id) DO UPDATE
  SET target_group_id = EXCLUDED.target_group_id
  WHERE role_permissions.target_group_id IS NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  r.name                            AS role_name,
  COUNT(rp.permission_id)           AS permission_count,
  COUNT(rp.target_group_id)         AS with_target_group
FROM  roles r
LEFT  JOIN role_permissions rp ON rp.role_id = r.id
GROUP BY r.name
ORDER BY r.name;

-- =============================================================================
-- END OF MIGRATION 103
-- =============================================================================
