-- =============================================================================
-- Migration 273: Employee Bank Accounts — Core Schema
--
-- Creates two new satellite tables for multi-country, effective-dated
-- bank account management.
--
-- TABLES
-- ──────
--   employee_bank_accounts     — One row per version of each bank account.
--                                Active record = effective_to = '9999-12-31'.
--                                Multiple accounts per employee allowed.
--                                Accounts linked by bank_account_group_id.
--
--   employee_bank_attachments  — Proof-of-account files stored in Supabase
--                                Storage bucket hr-attachments.
--                                Path: bank-accounts/{employee_id}/{group_id}/{file}
--
-- DESIGN NOTES
-- ────────────
--   Effective dating: driven by effective_from / effective_to. No is_active flag.
--   Group ID:         bank_account_group_id groups all versions of one account.
--                     "Add New Account" = new UUID. "Amend" = same UUID.
--                     The group_id is invisible to users.
--   Primary flag:     One primary per employee enforced by partial unique index.
--                     Auto-inherited when amending the same group.
--   Country-specific: Field constraints enforced by CHECK constraints keyed on
--                     country_code (alpha-3 ISO: IND, LKA, PAK, SAU).
--   RLS:              Two permission codes — employee.view_bank_accounts and
--                     employee.edit_bank_accounts — seeded in Migration 274.
--                     Scope controlled by Target Groups (same as address).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. employee_bank_accounts
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE employee_bank_accounts (
  id                      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id             UUID         NOT NULL REFERENCES employees(id)  ON DELETE CASCADE,
  bank_account_group_id   UUID         NOT NULL DEFAULT gen_random_uuid(),
  country_code            TEXT         NOT NULL,
  currency_code           TEXT         NOT NULL,
  bank_name               TEXT         NOT NULL,
  branch_name             TEXT,
  branch_code             TEXT,
  account_holder_name     TEXT         NOT NULL,
  account_number          TEXT         NOT NULL,
  ifsc_code               TEXT,
  iban                    TEXT,
  swift_bic               TEXT,
  is_primary              BOOLEAN      NOT NULL DEFAULT false,
  effective_from          DATE         NOT NULL,
  effective_to            DATE         NOT NULL DEFAULT '9999-12-31',
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by              UUID         NOT NULL REFERENCES profiles(id),
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by              UUID         NOT NULL REFERENCES profiles(id),

  -- ── Ordering ────────────────────────────────────────────────────────────
  CONSTRAINT chk_bank_effective_order
    CHECK (effective_to >= effective_from),

  -- effective_from must always be the 1st of the month
  CONSTRAINT chk_bank_effective_from_first_of_month
    CHECK (EXTRACT(DAY FROM effective_from) = 1),

  -- ── Country-specific mandatory fields ───────────────────────────────────
  -- IND: IFSC code is required
  CONSTRAINT chk_bank_ifsc_required_for_ind
    CHECK (country_code != 'IND' OR ifsc_code IS NOT NULL),

  -- LKA: Branch code is required
  CONSTRAINT chk_bank_branch_code_required_for_lka
    CHECK (country_code != 'LKA' OR branch_code IS NOT NULL),

  -- PAK / SAU: IBAN is required
  CONSTRAINT chk_bank_iban_required_for_pak_sau
    CHECK (country_code NOT IN ('PAK', 'SAU') OR iban IS NOT NULL)
);

COMMENT ON TABLE employee_bank_accounts IS
  'Effective-dated bank account records. Active record = effective_to = ''9999-12-31''. '
  'Multiple accounts per employee are allowed. All versions of the same account '
  'share a bank_account_group_id. Mig 273: initial creation.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

-- Fast employee lookups (primary query pattern)
CREATE INDEX idx_bank_accounts_employee
  ON employee_bank_accounts(employee_id);

-- Group lookup for amendments
CREATE INDEX idx_bank_accounts_group
  ON employee_bank_accounts(bank_account_group_id);

-- Active records only (most frequent query pattern)
CREATE INDEX idx_bank_accounts_active
  ON employee_bank_accounts(employee_id, effective_to)
  WHERE effective_to = '9999-12-31';

-- ── Partial unique indexes ────────────────────────────────────────────────────

-- One primary account per employee (active records only)
CREATE UNIQUE INDEX uq_bank_accounts_primary_active
  ON employee_bank_accounts(employee_id)
  WHERE is_primary = true AND effective_to = '9999-12-31';

-- No duplicate active IBAN per employee
CREATE UNIQUE INDEX uq_bank_accounts_iban_active
  ON employee_bank_accounts(iban)
  WHERE effective_to = '9999-12-31' AND iban IS NOT NULL;

-- No duplicate active account number per country per employee
CREATE UNIQUE INDEX uq_bank_accounts_number_active
  ON employee_bank_accounts(employee_id, country_code, account_number)
  WHERE effective_to = '9999-12-31';

-- ── updated_at trigger ────────────────────────────────────────────────────────

CREATE TRIGGER trg_employee_bank_accounts_updated_at
  BEFORE UPDATE ON employee_bank_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. employee_bank_attachments
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE employee_bank_attachments (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_account_id  UUID         NOT NULL REFERENCES employee_bank_accounts(id) ON DELETE CASCADE,
  employee_id      UUID         NOT NULL REFERENCES employees(id),
  file_name        TEXT         NOT NULL,
  file_type        TEXT         NOT NULL,
  file_size        INTEGER      NOT NULL CHECK (file_size > 0),
  storage_path     TEXT         NOT NULL,
  uploaded_by      UUID         NOT NULL REFERENCES profiles(id),
  uploaded_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  is_active        BOOLEAN      NOT NULL DEFAULT true
);

COMMENT ON TABLE employee_bank_attachments IS
  'Proof-of-account files attached to employee bank account records. '
  'Stored in the hr-attachments bucket at bank-accounts/{employee_id}/{group_id}/{filename}. '
  'is_active = false soft-deletes without removing the storage file. Mig 273: initial creation.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

CREATE INDEX idx_bank_attachments_account
  ON employee_bank_attachments(bank_account_id);

CREATE INDEX idx_bank_attachments_employee
  ON employee_bank_attachments(employee_id);

-- Active attachments only (most common query)
CREATE INDEX idx_bank_attachments_active
  ON employee_bank_attachments(bank_account_id)
  WHERE is_active = true;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Row Level Security — employee_bank_accounts
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE employee_bank_accounts ENABLE ROW LEVEL SECURITY;

-- SELECT: can view if has view_bank_accounts OR edit_bank_accounts permission
-- (via Target Groups), OR viewing own record as employee
CREATE POLICY eba_select ON employee_bank_accounts FOR SELECT
  USING (
    user_can('bank_accounts', 'view', employee_id)
    OR user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
  );

-- INSERT: admin/HR with edit permission via Target Groups, OR employee editing own
CREATE POLICY eba_insert ON employee_bank_accounts FOR INSERT
  WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_bank_accounts')
    )
  );

-- UPDATE: same as INSERT — needed for effective_to close-out during amendments
CREATE POLICY eba_update ON employee_bank_accounts FOR UPDATE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_bank_accounts')
    )
  );

-- DELETE: admin/HR only — employees cannot delete bank records
CREATE POLICY eba_delete ON employee_bank_accounts FOR DELETE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Row Level Security — employee_bank_attachments
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE employee_bank_attachments ENABLE ROW LEVEL SECURITY;

-- SELECT: mirrors the bank account policy
CREATE POLICY ebat_select ON employee_bank_attachments FOR SELECT
  USING (
    user_can('bank_accounts', 'view', employee_id)
    OR user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
  );

-- INSERT: can attach if can edit the account
CREATE POLICY ebat_insert ON employee_bank_attachments FOR INSERT
  WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_bank_accounts')
    )
  );

-- UPDATE (soft delete via is_active): same as insert
CREATE POLICY ebat_update ON employee_bank_attachments FOR UPDATE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('employee.edit_bank_accounts')
    )
  );

-- Hard delete: admin/HR only
CREATE POLICY ebat_delete ON employee_bank_attachments FOR DELETE
  USING (
    user_can('bank_accounts', 'edit', employee_id)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Verification
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  tablename,
  policyname,
  cmd
FROM pg_policies
WHERE tablename IN ('employee_bank_accounts', 'employee_bank_attachments')
ORDER BY tablename, cmd;

SELECT
  indexname,
  indexdef
FROM pg_indexes
WHERE tablename IN ('employee_bank_accounts', 'employee_bank_attachments')
ORDER BY tablename, indexname;

-- =============================================================================
-- END OF MIGRATION 273
-- =============================================================================
