-- =============================================================================
-- Migration 146: Drop role_permissions table and associated sync machinery
--
-- WHY
-- ───
-- role_permissions was the original RBAC enforcement table. Migration 107
-- rewrote user_can() to read permission_set_assignments directly — making
-- role_permissions unreachable by any enforcement path. Migration 106 had
-- added a trigger-sync bridge to keep role_permissions populated, but since
-- nothing reads it, those triggers have been burning cycles on every
-- permission change for no reason.
--
-- WHAT IS REMOVED
-- ───────────────
--   Triggers  trg_psi_sync              ON permission_set_items
--             trg_psa_sync              ON permission_set_assignments
--
--   Functions trg_sync_on_set_item_change()
--             trg_sync_on_set_assignment_change()
--             sync_role_permissions_from_set(uuid)
--
--   Table     role_permissions          (CASCADE drops indexes + FK refs)
--
-- WHAT IS NOT TOUCHED
-- ───────────────────
--   user_can()                          — already reads PSA directly (mig 107)
--   get_my_permissions()                — already reads PSA directly (mig 107)
--   permission_set_assignments          — unchanged, this is the source of truth
--   permission_set_items                — unchanged
--   All RLS policies                    — unchanged (they call user_can())
--
-- SAFETY CHECK
-- ────────────
-- user_can() prosrc is verified below to contain no reference to role_permissions
-- before the table is dropped. If that check returns false, stop and investigate.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Pre-flight: confirm user_can() does NOT reference role_permissions
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_references_rp boolean;
BEGIN
  SELECT prosrc LIKE '%role_permissions%'
  INTO   v_references_rp
  FROM   pg_proc
  WHERE  proname = 'user_can'
  LIMIT  1;

  IF v_references_rp THEN
    RAISE EXCEPTION
      'ABORT: user_can() still references role_permissions. '
      'Do not drop the table until user_can() is updated. '
      'Check migration 107 was applied correctly.';
  END IF;

  RAISE NOTICE 'Pre-flight passed: user_can() does not reference role_permissions.';
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Drop sync triggers (must drop before functions)
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_psi_sync ON permission_set_items;
DROP TRIGGER IF EXISTS trg_psa_sync ON permission_set_assignments;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Drop sync functions
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS trg_sync_on_set_item_change();
DROP FUNCTION IF EXISTS trg_sync_on_set_assignment_change();
DROP FUNCTION IF EXISTS sync_role_permissions_from_set(uuid);


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Drop the table (CASCADE removes indexes, FK constraints, policies)
-- ─────────────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS role_permissions CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Table gone
SELECT COUNT(*) = 0 AS table_dropped
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'role_permissions';

-- 2. Sync triggers gone
SELECT COUNT(*) = 0 AS triggers_dropped
FROM   information_schema.triggers
WHERE  trigger_name IN ('trg_psi_sync', 'trg_psa_sync');

-- 3. Sync functions gone
SELECT COUNT(*) = 0 AS functions_dropped
FROM   pg_proc
WHERE  proname IN (
  'sync_role_permissions_from_set',
  'trg_sync_on_set_item_change',
  'trg_sync_on_set_assignment_change'
);

-- 4. user_can() still intact and still on PSA
SELECT
  proname,
  prosrc LIKE '%permission_set_assignments%' AS reads_psa,
  prosrc NOT LIKE '%role_permissions%'       AS no_rp_ref
FROM pg_proc
WHERE proname = 'user_can';

-- =============================================================================
-- END OF MIGRATION 146
--
-- After this migration user_can() has exactly two data paths:
--   Path A: is_super_admin()        → immediate true
--   Path B: p_owner IS NULL         → admin module, PSA chain, no target scope
--   Path D: p_owner IS NOT NULL     → scope_type-aware PSA + target_groups join
--
-- permission_set_assignments is the single source of truth for all
-- permission enforcement at both the DB (RLS) and UI (get_my_permissions) layers.
-- =============================================================================
