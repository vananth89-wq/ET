-- =============================================================================
-- Migration 328: employee_bank_account_set + employee_bank_account_item schema
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §3.2
--
-- WHAT
-- ────
-- Parent-child set-snapshot tables for bank accounts, mirroring the dependent
-- set tables (mig 320). One "set" row per change event; N "item" rows inside.
-- The set model enables a single workflow request to cover all bank account
-- changes atomically (add/amend/remove any combination).
--
-- KEY DIFFERENCES FROM DEPENDENT SET (mig 320)
-- ─────────────────────────────────────────────
--   • Stable identity: bank_account_group_id (UUID, not a TEXT code)
--   • effective_from: must be 1st of the current month (enforced in submit RPC)
--   • Exactly one item per set may have is_primary=true (partial unique index)
--   • Country-specific field rules (CHECK constraints mirror employee_bank_accounts)
--
-- ROLLBACK
-- ────────
-- DROP TABLE employee_bank_account_item;
-- DROP TABLE employee_bank_account_set;
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. employee_bank_account_set (parent)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE employee_bank_account_set (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id    UUID         NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from DATE         NOT NULL,
  effective_to   DATE         NOT NULL DEFAULT '9999-12-31'::date,
  is_active      BOOLEAN      NOT NULL DEFAULT true,
  created_by     UUID         REFERENCES profiles(id),
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_bank_set_effective_order
    CHECK (effective_to >= effective_from)
);

COMMENT ON TABLE employee_bank_account_set IS
  'Set-snapshot parent for bank accounts. One row per change event. '
  'Active set = is_active = true AND effective_to = ''9999-12-31''. '
  'Items live in employee_bank_account_item. '
  'Legacy per-row table (employee_bank_accounts) remains until Phase 6 cleanup. '
  'Mig 328.';

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX uq_bank_set_active_per_employee
  ON employee_bank_account_set (employee_id)
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

CREATE INDEX idx_bank_set_employee
  ON employee_bank_account_set (employee_id, effective_from DESC);

CREATE TRIGGER trg_bank_set_updated_at
  BEFORE UPDATE ON employee_bank_account_set
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. employee_bank_account_item (children)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE employee_bank_account_item (
  id                    UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id                UUID    NOT NULL REFERENCES employee_bank_account_set(id) ON DELETE CASCADE,
  bank_account_group_id UUID    NOT NULL,
  country_code          TEXT    NOT NULL,
  currency_code         TEXT    NOT NULL,
  bank_name             TEXT    NOT NULL,
  branch_name           TEXT,
  branch_code           TEXT,
  account_holder_name   TEXT    NOT NULL,
  account_number        TEXT    NOT NULL,
  ifsc_code             TEXT,
  iban                  TEXT,
  swift_bic             TEXT,
  is_primary            BOOLEAN NOT NULL DEFAULT false,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_bank_item_ind_ifsc   CHECK (country_code <> 'IND' OR ifsc_code   IS NOT NULL),
  CONSTRAINT chk_bank_item_pak_iban   CHECK (country_code <> 'PAK' OR iban        IS NOT NULL),
  CONSTRAINT chk_bank_item_sau_iban   CHECK (country_code <> 'SAU' OR iban        IS NOT NULL),
  CONSTRAINT chk_bank_item_lka_branch CHECK (country_code <> 'LKA' OR branch_code IS NOT NULL)
);

COMMENT ON TABLE employee_bank_account_item IS
  'One row per bank account within a set. bank_account_group_id is the stable '
  'identity across successive sets. Exactly one item per set must have '
  'is_primary=true (enforced by uq_bank_item_primary_per_set). Mig 328.';

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX uq_bank_item_group_per_set
  ON employee_bank_account_item (set_id, bank_account_group_id);

CREATE UNIQUE INDEX uq_bank_item_primary_per_set
  ON employee_bank_account_item (set_id)
  WHERE is_primary = true;

CREATE INDEX idx_bank_item_group
  ON employee_bank_account_item (bank_account_group_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Row Level Security — modelled exactly on mig 320 (dependent set)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE employee_bank_account_set  ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_bank_account_item ENABLE ROW LEVEL SECURITY;

-- ── Set policies ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS bank_set_select ON employee_bank_account_set;
CREATE POLICY bank_set_select
  ON employee_bank_account_set
  FOR SELECT
  TO authenticated
  USING (
    is_super_admin()
    OR user_can('bank_accounts', 'view', employee_id)
    OR user_can('bank_accounts', 'edit', employee_id)
    OR (
      -- Path B: hire-pipeline HR-guard (same pattern as dep_set_select, mig 320)
      user_can('bank_accounts', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = employee_bank_account_set.employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

DROP POLICY IF EXISTS bank_set_insert ON employee_bank_account_set;
CREATE POLICY bank_set_insert
  ON employee_bank_account_set
  FOR INSERT
  TO authenticated
  WITH CHECK (is_super_admin());   -- all writes via SECURITY DEFINER RPCs

DROP POLICY IF EXISTS bank_set_update ON employee_bank_account_set;
CREATE POLICY bank_set_update
  ON employee_bank_account_set
  FOR UPDATE
  TO authenticated
  USING (is_super_admin());

DROP POLICY IF EXISTS bank_set_delete ON employee_bank_account_set;
CREATE POLICY bank_set_delete
  ON employee_bank_account_set
  FOR DELETE
  TO authenticated
  USING (is_super_admin());

-- ── Item policies ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS bank_item_select ON employee_bank_account_item;
CREATE POLICY bank_item_select
  ON employee_bank_account_item
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_bank_account_set s
      WHERE s.id = employee_bank_account_item.set_id
        AND (
          is_super_admin()
          OR user_can('bank_accounts', 'view', s.employee_id)
          OR user_can('bank_accounts', 'edit', s.employee_id)
          OR (
            user_can('bank_accounts', 'view', NULL)
            AND user_can('hire_employee', 'view', NULL)
            AND EXISTS (
              SELECT 1 FROM employees e
              WHERE e.id = s.employee_id
                AND e.status IN ('Draft', 'Incomplete', 'Pending')
            )
          )
        )
    )
  );

DROP POLICY IF EXISTS bank_item_insert ON employee_bank_account_item;
CREATE POLICY bank_item_insert
  ON employee_bank_account_item
  FOR INSERT
  TO authenticated
  WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS bank_item_update ON employee_bank_account_item;
CREATE POLICY bank_item_update
  ON employee_bank_account_item
  FOR UPDATE
  TO authenticated
  USING (is_super_admin());

DROP POLICY IF EXISTS bank_item_delete ON employee_bank_account_item;
CREATE POLICY bank_item_delete
  ON employee_bank_account_item
  FOR DELETE
  TO authenticated
  USING (is_super_admin());


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'employee_bank_account_set'  AND relkind = 'r') THEN
    RAISE EXCEPTION 'mig 328: employee_bank_account_set table missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'employee_bank_account_item' AND relkind = 'r') THEN
    RAISE EXCEPTION 'mig 328: employee_bank_account_item table missing';
  END IF;
  RAISE NOTICE 'mig 328: employee_bank_account_set + employee_bank_account_item created';
END
$$;
