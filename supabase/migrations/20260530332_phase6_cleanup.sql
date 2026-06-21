-- Migration 332: Phase 6 cleanup — set-snapshot cutover
--
-- What this migration does:
--   1. Renames legacy effective-dated tables to _legacy (kept ≥2 weeks for rollback)
--   2. Drops dead legacy RPCs — no frontend caller exists after Phase 3+5 rewrites
--   3. Drops the now-dead FK on employee_dependent_attachments.dependent_id
--      (that column FK'd to employee_dependents.id which is now _legacy; the
--       join key for reads is dependent_code, not the row id)
--
-- What this migration does NOT do:
--   DROP TABLE employee_dependents_legacy / employee_bank_accounts_legacy
--   → Scheduled for migration 333+, at least 2 weeks after cutover (≥ 2026-06-14)
--
-- Safe to run: all five dropped RPCs have zero frontend callers as of Phase 5.
-- Idempotent: each step uses IF EXISTS.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Rename legacy tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE IF EXISTS employee_dependents
  RENAME TO employee_dependents_legacy;

ALTER TABLE IF EXISTS employee_bank_accounts
  RENAME TO employee_bank_accounts_legacy;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Drop dead legacy RPCs
-- ─────────────────────────────────────────────────────────────────────────────

-- Dependents legacy RPCs (replaced by submit_dependent_set / get_employee_dependent_set)
DROP FUNCTION IF EXISTS get_employee_dependents(uuid, boolean);
DROP FUNCTION IF EXISTS upsert_dependent(uuid, text, text, date, text, date, text, boolean);
DROP FUNCTION IF EXISTS remove_dependent(uuid, text, date);

-- Bank legacy RPCs (replaced by submit_bank_account_set / get_employee_bank_account_set)
DROP FUNCTION IF EXISTS get_employee_bank_accounts(uuid, boolean);

-- upsert_bank_account has many overloads accumulated over time — drop by name
-- (CASCADE is safe: no DB object depends on it after Phase 5)
DROP FUNCTION IF EXISTS upsert_bank_account(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text, boolean, date, jsonb, boolean
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Drop dead FK on employee_dependent_attachments
--
-- The FK employee_dependent_attachments.dependent_id → employee_dependents.id
-- is now dead because employee_dependents was renamed above. The column stays
-- (it is already null-able in practice and not used for reads — reads join on
-- dependent_code). We drop just the constraint, not the column.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_constraint text;
BEGIN
  -- Find the FK constraint name dynamically (it varies by migration history)
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'employee_dependent_attachments'::regclass
    AND contype  = 'f'
    AND confrelid = (
      SELECT oid FROM pg_class
      WHERE relname = 'employee_dependents_legacy'   -- already renamed above
        AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    )
  LIMIT 1;

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE employee_dependent_attachments DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped FK constraint % on employee_dependent_attachments', v_constraint;
  ELSE
    RAISE NOTICE 'No FK from employee_dependent_attachments to legacy dependents table — skipping';
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Validation
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_dep_set_count  INTEGER;
  v_bank_set_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_dep_set_count  FROM employee_dependent_set  WHERE is_active = true;
  SELECT COUNT(*) INTO v_bank_set_count FROM employee_bank_account_set WHERE is_active = true;

  RAISE NOTICE 'mig 332: cleanup complete — % active dependent sets, % active bank sets',
    v_dep_set_count, v_bank_set_count;

  -- Sanity: new set tables must still be accessible
  IF v_dep_set_count IS NULL OR v_bank_set_count IS NULL THEN
    RAISE EXCEPTION 'mig 332: validation failed — set tables not accessible after cleanup';
  END IF;
END $$;

COMMIT;
