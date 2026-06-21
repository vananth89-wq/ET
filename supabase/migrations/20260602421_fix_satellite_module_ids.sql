-- =============================================================================
-- Migration 421 — Fix module_id on satellite permission rows
-- =============================================================================
--
-- ROOT CAUSE
-- ──────────
-- user_can(p_module, p_action, p_owner) resolves permissions via:
--
--   JOIN modules m ON m.id = p.module_id
--   WHERE m.code = p_module
--     AND p.action = p_action
--
-- Satellite permissions (bank_accounts.*, dependents.*) were seeded with
-- module_id pointing to the 'employee' module (code = 'employee') as a
-- workaround. That makes m.code = 'employee', not 'bank_accounts' or
-- 'dependents', so user_can('bank_accounts', ...) and user_can('dependents', ...)
-- ALWAYS return false — regardless of what is checked in the permission matrix.
--
-- FIX
-- ───
-- 1. Insert 'bank_accounts' and 'dependents' modules (if not present).
-- 2. UPDATE module_id on all bank_accounts.* and dependents.* permission rows
--    to point to their correct module.
-- 3. job_relationships already has its own module (seeded in mig 359) — verify.
--
-- BLAST-RADIUS
-- ────────────
-- • user_can('bank_accounts', ...) and user_can('dependents', ...) will now
--   return correct results for all HR/admin users whose permission sets have
--   these permissions checked.
-- • No data is deleted. permission_set_items rows already stored the correct
--   permission UUID — only the permissions.module_id FK changes.
-- • PermissionMatrix UI continues to work unchanged (it looks up by p.code,
--   not p.module_id).
-- • RLS policies and RPCs that call user_can('bank_accounts'/'dependents', ...)
--   will now correctly grant access to users with those permissions.
-- =============================================================================

DO $$
DECLARE
  v_sort_max   int;
  v_mod_bank   uuid;
  v_mod_dep    uuid;
  v_mod_jr     uuid;
BEGIN

  -- ── 1. Ensure bank_accounts module exists ──────────────────────────────────
  SELECT id INTO v_mod_bank FROM modules WHERE code = 'bank_accounts';

  IF v_mod_bank IS NULL THEN
    SELECT COALESCE(MAX(sort_order), 100) + 1 INTO v_sort_max FROM modules;
    INSERT INTO modules (code, name, active, sort_order)
    VALUES ('bank_accounts', 'Bank Accounts', true, v_sort_max)
    RETURNING id INTO v_mod_bank;
    RAISE NOTICE 'Created bank_accounts module: %', v_mod_bank;
  ELSE
    RAISE NOTICE 'bank_accounts module already exists: %', v_mod_bank;
  END IF;

  -- ── 2. Ensure dependents module exists ─────────────────────────────────────
  SELECT id INTO v_mod_dep FROM modules WHERE code = 'dependents';

  IF v_mod_dep IS NULL THEN
    SELECT COALESCE(MAX(sort_order), 100) + 1 INTO v_sort_max FROM modules;
    INSERT INTO modules (code, name, active, sort_order)
    VALUES ('dependents', 'Dependents', true, v_sort_max)
    RETURNING id INTO v_mod_dep;
    RAISE NOTICE 'Created dependents module: %', v_mod_dep;
  ELSE
    RAISE NOTICE 'dependents module already exists: %', v_mod_dep;
  END IF;

  -- ── 3. Verify job_relationships module ─────────────────────────────────────
  SELECT id INTO v_mod_jr FROM modules WHERE code = 'job_relationships';
  IF v_mod_jr IS NULL THEN
    RAISE WARNING 'job_relationships module not found — its permissions may be broken too';
  ELSE
    RAISE NOTICE 'job_relationships module OK: %', v_mod_jr;
  END IF;

  -- ── 4. Re-point bank_accounts.* permissions ────────────────────────────────
  UPDATE permissions
  SET module_id = v_mod_bank
  WHERE code LIKE 'bank_accounts.%'
    AND module_id <> v_mod_bank;

  RAISE NOTICE 'Updated % bank_accounts permissions', (
    SELECT COUNT(*) FROM permissions
    WHERE code LIKE 'bank_accounts.%' AND module_id = v_mod_bank
  );

  -- ── 5. Re-point dependents.* permissions ───────────────────────────────────
  UPDATE permissions
  SET module_id = v_mod_dep
  WHERE code LIKE 'dependents.%'
    AND module_id <> v_mod_dep;

  RAISE NOTICE 'Updated % dependents permissions', (
    SELECT COUNT(*) FROM permissions
    WHERE code LIKE 'dependents.%' AND module_id = v_mod_dep
  );

END;
$$;

-- =============================================================================
-- Verification
-- =============================================================================
DO $$
DECLARE
  v_bad int;
BEGIN
  SELECT COUNT(*) INTO v_bad
  FROM permissions p
  JOIN modules m ON m.id = p.module_id
  WHERE p.code LIKE 'bank_accounts.%' AND m.code <> 'bank_accounts';

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ABORT: % bank_accounts permissions still have wrong module_id', v_bad;
  END IF;

  SELECT COUNT(*) INTO v_bad
  FROM permissions p
  JOIN modules m ON m.id = p.module_id
  WHERE p.code LIKE 'dependents.%' AND m.code <> 'dependents';

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ABORT: % dependents permissions still have wrong module_id', v_bad;
  END IF;

  RAISE NOTICE 'Migration 421 verified: bank_accounts and dependents module_ids are correct.';
END;
$$;

-- Quick sanity check — show current state
SELECT p.code, m.code AS module_code, p.action
FROM permissions p
JOIN modules m ON m.id = p.module_id
WHERE p.code LIKE 'bank_accounts.%'
   OR p.code LIKE 'dependents.%'
ORDER BY p.code;

-- =============================================================================
-- END OF MIGRATION 421
-- =============================================================================
