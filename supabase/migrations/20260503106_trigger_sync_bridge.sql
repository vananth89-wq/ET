-- =============================================================================
-- Migration 106: Trigger Sync Bridge — materialise permission_set grants
--                into role_permissions so user_can() (RLS) enforces them.
--
-- BACKGROUND
-- ──────────
-- get_my_permissions() (UI gates) was fixed in migration 102/105 to UNION both
-- role_permissions and permission_set_assignments.
--
-- user_can() (called inside every RLS policy) still reads role_permissions only.
-- Permission Matrix grants therefore have zero effect on database-level access.
--
-- SOLUTION  (Option 1 from the Permission Bridge design doc)
-- ──────────────────────────────────────────────────────────
-- Add a permission_set_id FK column to role_permissions to mark trigger-synced
-- rows. Create a sync function that rebuilds those rows whenever a permission
-- set changes. Fire that function from triggers on both permission_set_items and
-- permission_set_assignments. Backfill all existing sets at migration time.
--
-- user_can() is UNCHANGED — it reads role_permissions as-is and now
-- automatically sees matrix grants because the rows exist there.
--
-- PREREQUISITE — Migration 103 constraint
-- ────────────────────────────────────────
-- Migration 103 added: UNIQUE (role_id, permission_id)
-- That would conflict with trigger-synced rows when the same (role, permission)
-- exists as both a legacy hand-crafted row and a set-synced row.
-- We replace it with a three-column composite unique index that distinguishes
-- the two sources.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Add permission_set_id FK column to role_permissions
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE role_permissions
  ADD COLUMN IF NOT EXISTS permission_set_id UUID
    REFERENCES permission_sets(id) ON DELETE CASCADE;

COMMENT ON COLUMN role_permissions.permission_set_id IS
  'NULL  = legacy direct grant (managed manually or by old tools). '
  'UUID  = synced from this permission_set by the trigger bridge. '
  'Trigger deletes + re-inserts rows with this set id whenever the set changes.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Replace the migration-103 two-column unique constraint
--         with a three-column composite unique index
-- ─────────────────────────────────────────────────────────────────────────────

-- Drop the two-column constraint added in migration 103 (if it exists)
ALTER TABLE role_permissions
  DROP CONSTRAINT IF EXISTS uq_role_permissions_role_perm;

-- New composite unique index distinguishes direct vs set-synced rows
CREATE UNIQUE INDEX IF NOT EXISTS uq_role_permissions_full
  ON role_permissions (
    role_id,
    permission_id,
    COALESCE(permission_set_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Sync function
--   Full rebuild of role_permissions rows sourced from a given permission_set.
--   Idempotent — safe to call multiple times.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_role_permissions_from_set(p_set_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Remove all synced rows for this set (cascade handles orphans)
  DELETE FROM role_permissions
  WHERE  permission_set_id = p_set_id;

  -- Re-insert from current set state
  INSERT INTO role_permissions (role_id, permission_id, permission_set_id)
  SELECT DISTINCT
    psa.role_id,
    psi.permission_id,
    p_set_id
  FROM   permission_set_assignments psa
  JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
  WHERE  psa.permission_set_id = p_set_id
    AND  psa.role_id IS NOT NULL
  ON CONFLICT DO NOTHING;
END;
$$;

COMMENT ON FUNCTION sync_role_permissions_from_set(UUID) IS
  'Rebuilds all role_permissions rows that are sourced from the given '
  'permission_set_id. Called by triggers and at backfill time. Idempotent.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Trigger functions
-- ─────────────────────────────────────────────────────────────────────────────

-- Trigger A: fired when permissions inside a set change
CREATE OR REPLACE FUNCTION trg_sync_on_set_item_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM sync_role_permissions_from_set(
    COALESCE(NEW.permission_set_id, OLD.permission_set_id)
  );
  RETURN NULL;
END;
$$;

-- Trigger B: fired when a set is assigned to / removed from a role
CREATE OR REPLACE FUNCTION trg_sync_on_set_assignment_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM sync_role_permissions_from_set(
    COALESCE(NEW.permission_set_id, OLD.permission_set_id)
  );
  RETURN NULL;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 5: Attach triggers
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_psi_sync ON permission_set_items;
CREATE TRIGGER trg_psi_sync
  AFTER INSERT OR UPDATE OR DELETE ON permission_set_items
  FOR EACH ROW EXECUTE FUNCTION trg_sync_on_set_item_change();

DROP TRIGGER IF EXISTS trg_psa_sync ON permission_set_assignments;
CREATE TRIGGER trg_psa_sync
  AFTER INSERT OR UPDATE OR DELETE ON permission_set_assignments
  FOR EACH ROW EXECUTE FUNCTION trg_sync_on_set_assignment_change();


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 6: Backfill — sync all existing permission sets
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM permission_sets LOOP
    PERFORM sync_role_permissions_from_set(r.id);
  END LOOP;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Column added
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_name = 'role_permissions'
  AND  column_name = 'permission_set_id';

-- 2. Triggers exist
SELECT trigger_name, event_object_table, event_manipulation
FROM   information_schema.triggers
WHERE  trigger_name IN ('trg_psi_sync', 'trg_psa_sync')
ORDER  BY trigger_name, event_manipulation;

-- 3. Row counts — should see synced rows with non-null permission_set_id
SELECT
  CASE WHEN permission_set_id IS NULL THEN 'direct grant' ELSE 'set-synced' END AS source,
  COUNT(*) AS rows
FROM role_permissions
GROUP BY 1;

-- =============================================================================
-- END OF MIGRATION 106
-- =============================================================================
