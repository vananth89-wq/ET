-- =============================================================================
-- Migration 331: backfill employee_bank_account_set from employee_bank_accounts
--
-- DESIGN REFERENCE
-- ────────────────
-- docs/set-snapshot-design.md §8.2 (Backfill algorithm — Bank)
--
-- WHAT
-- ────
-- Populates the new set-snapshot tables (mig 328) from the legacy
-- employee_bank_accounts table.
--
-- SCOPE (Phase 4 pragmatic simplification)
-- ─────────────────────────────────────────
-- Bank accounts differ from dependents: accounts are amended individually, so
-- a clean "historical set snapshot" cannot always be reconstructed from
-- (effective_from, effective_to) date pairs alone. For Phase 4, this migration
-- only backfills the CURRENT ACTIVE SET (effective_to = '9999-12-31') for each
-- employee. Historical amendment rows remain in employee_bank_accounts (the
-- legacy table) and are accessible via get_employee_bank_accounts until Phase 6.
--
-- ALGORITHM
-- ──────────
-- For each employee that has ≥ 1 active legacy bank account:
--   1. Collect all rows WHERE effective_to = '9999-12-31'.
--   2. Create one employee_bank_account_set with:
--        effective_from = MIN(effective_from) across the employee's active accounts
--        effective_to   = '9999-12-31'
--        is_active      = true
--   3. Create one employee_bank_account_item per active account, preserving:
--        bank_account_group_id, country_code, currency_code, bank_name,
--        branch_name, branch_code, account_holder_name, account_number,
--        ifsc_code, iban, swift_bic, is_primary
--
-- IDEMPOTENCY
-- ───────────
-- Skips employees that already have an active set row (re-runnable).
--
-- VALIDATION
-- ──────────
-- After backfill:
--   • Every active legacy account has a corresponding item in the new set.
--   • Employee active-set count = legacy active-employee count (no gaps).
-- Aborts inside the transaction if validation fails.
--
-- ROLLBACK
-- ────────
-- DELETE FROM employee_bank_account_set WHERE id IN (<backfilled set ids>);
-- (Items cascade; this leaves employee_bank_accounts untouched.)
-- =============================================================================

DO $$
DECLARE
  v_emp_count      INTEGER := 0;
  v_set_count      INTEGER := 0;
  v_item_count     INTEGER := 0;
  v_skip_count     INTEGER := 0;

  v_emp_id         UUID;
  v_eff_from       DATE;
  v_new_set_id     UUID;
  v_acct           RECORD;

  -- Validation
  v_legacy_active  INTEGER;
  v_set_active     INTEGER;
  v_orphan_count   INTEGER;
  -- Post-loop totals (subqueries not allowed in RAISE params)
  v_total_sets     INTEGER;
  v_total_items    INTEGER;
BEGIN
  RAISE NOTICE 'mig 331 (pre): starting bank account set backfill';

  -- ── Count eligible employees ─────────────────────────────────────────────
  SELECT COUNT(DISTINCT employee_id)
    INTO v_emp_count
  FROM employee_bank_accounts
  WHERE effective_to = '9999-12-31'::date;

  RAISE NOTICE 'mig 331 (pre): % employees with active legacy bank accounts', v_emp_count;

  -- ── Main backfill loop ───────────────────────────────────────────────────
  FOR v_emp_id IN
    SELECT DISTINCT employee_id
    FROM employee_bank_accounts
    WHERE effective_to = '9999-12-31'::date
    ORDER BY employee_id
  LOOP
    -- Skip if already has an active set (idempotency)
    IF EXISTS (
      SELECT 1 FROM employee_bank_account_set
      WHERE employee_id = v_emp_id
        AND is_active   = true
        AND effective_to = '9999-12-31'::date
    ) THEN
      v_skip_count := v_skip_count + 1;
      CONTINUE;
    END IF;

    -- effective_from = earliest active account for this employee
    SELECT MIN(effective_from)
      INTO v_eff_from
    FROM employee_bank_accounts
    WHERE employee_id  = v_emp_id
      AND effective_to = '9999-12-31'::date;

    -- Snap to 1st of month (should already be the case per chk_bank_effective_from_first_of_month)
    v_eff_from := date_trunc('month', v_eff_from)::date;

    -- Insert set
    INSERT INTO employee_bank_account_set (
      employee_id, effective_from, effective_to, is_active, created_by
    ) VALUES (
      v_emp_id, v_eff_from, '9999-12-31'::date, true, NULL
    )
    RETURNING id INTO v_new_set_id;

    v_set_count := v_set_count + 1;

    -- Insert one item per active legacy account
    FOR v_acct IN
      SELECT
        bank_account_group_id,
        country_code,
        currency_code,
        bank_name,
        branch_name,
        branch_code,
        account_holder_name,
        account_number,
        ifsc_code,
        iban,
        swift_bic,
        is_primary
      FROM employee_bank_accounts
      WHERE employee_id  = v_emp_id
        AND effective_to = '9999-12-31'::date
      ORDER BY is_primary DESC, bank_name
    LOOP
      INSERT INTO employee_bank_account_item (
        set_id,
        bank_account_group_id,
        country_code,
        currency_code,
        bank_name,
        branch_name,
        branch_code,
        account_holder_name,
        account_number,
        ifsc_code,
        iban,
        swift_bic,
        is_primary
      ) VALUES (
        v_new_set_id,
        v_acct.bank_account_group_id,
        v_acct.country_code,
        v_acct.currency_code,
        v_acct.bank_name,
        v_acct.branch_name,
        v_acct.branch_code,
        v_acct.account_holder_name,
        v_acct.account_number,
        v_acct.ifsc_code,
        v_acct.iban,
        v_acct.swift_bic,
        v_acct.is_primary
      );
      v_item_count := v_item_count + 1;
    END LOOP;
  END LOOP;

  SELECT COUNT(*) INTO v_total_sets  FROM employee_bank_account_set;
  SELECT COUNT(*) INTO v_total_items FROM employee_bank_account_item;

  RAISE NOTICE 'mig 331 (post): % sets (+%), % items (+%), % employees skipped (already had set)',
    v_total_sets, v_set_count,
    v_total_items, v_item_count,
    v_skip_count;

  -- ── Validation ────────────────────────────────────────────────────────────

  -- 1. Every active legacy account must have a matching item in a set
  SELECT COUNT(*)
    INTO v_orphan_count
  FROM employee_bank_accounts eba
  WHERE eba.effective_to = '9999-12-31'::date
    AND NOT EXISTS (
      SELECT 1
      FROM employee_bank_account_item  i
      JOIN employee_bank_account_set   s ON s.id = i.set_id
      WHERE i.bank_account_group_id = eba.bank_account_group_id
        AND s.employee_id = eba.employee_id
    );

  IF v_orphan_count > 0 THEN
    RAISE EXCEPTION
      'mig 331: validation failed — % active legacy account(s) have no '
      'corresponding item in employee_bank_account_item',
      v_orphan_count;
  END IF;

  -- 2. Active set count must equal number of employees with active accounts
  SELECT COUNT(DISTINCT employee_id)
    INTO v_legacy_active
  FROM employee_bank_accounts
  WHERE effective_to = '9999-12-31'::date;

  SELECT COUNT(*)
    INTO v_set_active
  FROM employee_bank_account_set
  WHERE is_active = true AND effective_to = '9999-12-31'::date;

  IF v_set_active < v_legacy_active THEN
    RAISE EXCEPTION
      'mig 331: validation failed — % active sets but % employees have active '
      'legacy accounts (gap of %)',
      v_set_active, v_legacy_active, v_legacy_active - v_set_active;
  END IF;

  RAISE NOTICE 'mig 331: backfill complete — % active sets, % items now mirror legacy state',
    v_set_active, (SELECT COUNT(*) FROM employee_bank_account_item);
END
$$;
