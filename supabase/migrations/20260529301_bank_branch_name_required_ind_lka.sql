-- =============================================================================
-- Migration 301: Branch Name mandatory for IND and LKA
--
-- Spec gap (point 1 from validation audit, 2026-05-29):
--   Country-mandatory fields are supposed to be enforced at DB CHECK + app.
--   Mig 273 added CHECKs for IFSC (IND), branch_code (LKA), and IBAN (PAK/SAU)
--   but missed branch_name for IND and LKA. Frontend (BankAccountsPortlet.tsx)
--   does enforce it, but a direct RPC call or admin/HR PATH A insert can write
--   NULL branch_name for an IND/LKA row.
--
-- This migration:
--   1. Adds chk_bank_branch_name_required_for_ind_lka CHECK constraint.
--      Pre-flights existing data — aborts if any rows would violate.
--   2. Adds the matching guard at the top of upsert_bank_account so a friendly
--      JSON error is returned instead of letting the constraint blow up.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Pre-flight: refuse to add the constraint if existing rows would violate
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_violations int;
BEGIN
  SELECT count(*)
    INTO v_violations
    FROM employee_bank_accounts
   WHERE country_code IN ('IND', 'LKA')
     AND (branch_name IS NULL OR trim(branch_name) = '');

  IF v_violations > 0 THEN
    RAISE EXCEPTION
      'Migration 301 aborted: % existing IND/LKA rows have NULL/empty branch_name. '
      'Backfill required before adding chk_bank_branch_name_required_for_ind_lka.',
      v_violations;
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CHECK constraint
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE employee_bank_accounts
  ADD CONSTRAINT chk_bank_branch_name_required_for_ind_lka
  CHECK (
    country_code NOT IN ('IND', 'LKA')
    OR (branch_name IS NOT NULL AND trim(branch_name) <> '')
  );

COMMENT ON CONSTRAINT chk_bank_branch_name_required_for_ind_lka
  ON employee_bank_accounts IS
  'Branch Name is mandatory for India (IND) and Sri Lanka (LKA) per the '
  'country-specific field rules. Mig 301.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. upsert_bank_account — add branch_name guard to country-mandatory block
--
-- Re-creates the function from mig 299 with one added IF block (lines 90-92).
-- All other logic preserved verbatim.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_bank_account(
  p_employee_id             uuid,
  p_bank_account_group_id   uuid        DEFAULT NULL,
  p_country_code            text        DEFAULT NULL,
  p_currency_code           text        DEFAULT NULL,
  p_bank_name               text        DEFAULT NULL,
  p_branch_name             text        DEFAULT NULL,
  p_branch_code             text        DEFAULT NULL,
  p_account_holder_name     text        DEFAULT NULL,
  p_account_number          text        DEFAULT NULL,
  p_ifsc_code               text        DEFAULT NULL,
  p_iban                    text        DEFAULT NULL,
  p_swift_bic               text        DEFAULT NULL,
  p_is_primary              boolean     DEFAULT false,
  p_effective_from          date        DEFAULT NULL,
  p_attachments             jsonb       DEFAULT '[]'::jsonb,
  p_is_new_hire             boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id         uuid   := auth.uid();
  v_today             date   := CURRENT_DATE;
  v_day_of_month      int    := EXTRACT(DAY FROM v_today);
  v_month_first       date   := date_trunc('month', v_today)::date;
  v_is_bank_exception boolean;
  v_prev_active       employee_bank_accounts%ROWTYPE;
  v_group_id          uuid;
  v_template_id       uuid;
  v_new_id            uuid;
BEGIN
  -- ── 1. Basic field presence ───────────────────────────────────────────────
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_id is required.');
  END IF;
  IF p_country_code IS NULL OR trim(p_country_code) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Country is required.');
  END IF;
  IF p_currency_code IS NULL OR trim(p_currency_code) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Currency is required.');
  END IF;
  IF p_bank_name IS NULL OR trim(p_bank_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Bank name is required.');
  END IF;
  IF p_account_holder_name IS NULL OR trim(p_account_holder_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Account holder name is required.');
  END IF;
  IF p_account_number IS NULL OR trim(p_account_number) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Account number is required.');
  END IF;
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Effective from date is required.');
  END IF;

  -- ── 2. Country-specific mandatory fields ─────────────────────────────────
  -- ADDED (mig 301): Branch Name mandatory for IND and LKA
  IF p_country_code IN ('IND', 'LKA')
     AND (p_branch_name IS NULL OR trim(p_branch_name) = '') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Branch name is required for ' || p_country_code || '.'
    );
  END IF;
  IF p_country_code = 'IND' AND (p_ifsc_code IS NULL OR trim(p_ifsc_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IFSC code is required for India.');
  END IF;
  IF p_country_code = 'LKA' AND (p_branch_code IS NULL OR trim(p_branch_code) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Branch code is required for Sri Lanka.');
  END IF;
  IF p_country_code IN ('PAK', 'SAU') AND (p_iban IS NULL OR trim(p_iban) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IBAN is required for ' || p_country_code || '.');
  END IF;

  -- ── 3. Attachment is mandatory ────────────────────────────────────────────
  IF p_attachments IS NULL OR jsonb_array_length(p_attachments) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'At least one proof-of-account attachment is required.');
  END IF;

  -- ── 4. Date cutoff checks (skipped for new hires and exempt roles) ─────────
  v_is_bank_exception := has_role('bank_exceptions') OR has_role('admin') OR has_role('hr');

  IF NOT p_is_new_hire AND NOT v_is_bank_exception THEN
    -- ESS submission: blocked after the 15th of the current month
    IF v_day_of_month > 15 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Bank account changes can only be submitted on or before the 15th of the month. '
          'Today is the %sth. Please resubmit from the 1st of next month.',
          v_day_of_month
        )
      );
    END IF;

    -- effective_from must be exactly the 1st of the current month
    IF p_effective_from <> v_month_first THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', format(
          'Effective from date must be the 1st of the current month (%s). '
          'Please select %s and resubmit.',
          to_char(v_month_first, 'DD Mon YYYY'),
          to_char(v_month_first, 'DD Mon YYYY')
        )
      );
    END IF;
  END IF;

  -- ── 5. Resolve group_id ───────────────────────────────────────────────────
  IF p_bank_account_group_id IS NOT NULL THEN
    -- Amendment: verify the group belongs to this employee
    SELECT * INTO v_prev_active
    FROM   employee_bank_accounts
    WHERE  bank_account_group_id = p_bank_account_group_id
      AND  employee_id           = p_employee_id
      AND  effective_to          = '9999-12-31'::date
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'No active record found for the given bank_account_group_id.'
      );
    END IF;
    v_group_id := p_bank_account_group_id;
  ELSE
    -- New account: generate a fresh group UUID
    v_group_id := gen_random_uuid();
  END IF;

  -- ── 6. Check for workflow assignment ──────────────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_bank', v_caller_id);

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    -- Close the previous active version if this is an amendment
    IF v_prev_active.id IS NOT NULL THEN
      UPDATE employee_bank_accounts
      SET    effective_to = p_effective_from - interval '1 day',
             updated_at   = now(),
             updated_by   = v_caller_id
      WHERE  id = v_prev_active.id;
    END IF;

    -- Insert the new version
    INSERT INTO employee_bank_accounts (
      employee_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code, account_holder_name,
      account_number, ifsc_code, iban, swift_bic,
      is_primary, effective_from, effective_to,
      created_by, updated_by
    ) VALUES (
      p_employee_id, v_group_id, p_country_code, p_currency_code,
      p_bank_name, p_branch_name, p_branch_code, p_account_holder_name,
      p_account_number, p_ifsc_code, p_iban, p_swift_bic,
      p_is_primary, p_effective_from, '9999-12-31'::date,
      v_caller_id, v_caller_id
    )
    RETURNING id INTO v_new_id;

    -- Insert attachments
    IF p_attachments IS NOT NULL AND jsonb_array_length(p_attachments) > 0 THEN
      INSERT INTO employee_bank_attachments (
        bank_account_id, employee_id, file_name, file_type, file_size,
        storage_path, uploaded_by
      )
      SELECT
        v_new_id,
        p_employee_id,
        att->>'file_name',
        att->>'file_type',
        (att->>'file_size')::integer,
        att->>'storage_path',
        v_caller_id
      FROM jsonb_array_elements(p_attachments) AS att;
    END IF;

    RETURN jsonb_build_object('ok', true, 'bank_account_id', v_new_id, 'workflow_pending', false);

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assigned → stage proposed_data in workflow_pending_changes
  -- ════════════════════════════════════════════════════════════════════════════
  ELSE

    DECLARE
      v_proposed jsonb := jsonb_build_object(
        'employee_id',            p_employee_id,
        'bank_account_group_id',  v_group_id,
        'country_code',           p_country_code,
        'currency_code',          p_currency_code,
        'bank_name',              p_bank_name,
        'branch_name',            p_branch_name,
        'branch_code',            p_branch_code,
        'account_holder_name',    p_account_holder_name,
        'account_number',         p_account_number,
        'ifsc_code',              p_ifsc_code,
        'iban',                   p_iban,
        'swift_bic',              p_swift_bic,
        'is_primary',             p_is_primary,
        'effective_from',         p_effective_from,
        'prev_active_id',         v_prev_active.id,
        'attachments',            p_attachments
      );
      v_wpc_id  uuid;
      v_inst_id uuid;
    BEGIN
      INSERT INTO workflow_pending_changes (
        submitted_by, module_code, record_id, proposed_data, status
      ) VALUES (
        v_caller_id,
        'profile_bank',
        p_employee_id,
        v_proposed,
        'pending'
      )
      RETURNING id INTO v_wpc_id;

      INSERT INTO workflow_instances (
        template_id, submitted_by, module_code, record_id, pending_change_id, status
      ) VALUES (
        v_template_id,
        v_caller_id,
        'profile_bank',
        p_employee_id,
        v_wpc_id,
        'in_progress'
      )
      RETURNING id INTO v_inst_id;

      PERFORM seed_workflow_tasks(v_inst_id);

      RETURN jsonb_build_object('ok', true, 'workflow_pending', true, 'instance_id', v_inst_id);
    END;
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_bank_account(uuid, uuid, text, text, text, text, text, text, text, text, text, text, boolean, date, jsonb, boolean) IS
  'Inserts or amends an employee bank account record with effective-dating. '
  'PATH A (no workflow): writes directly. PATH B (workflow assigned): stages in workflow_pending_changes. '
  'Date rules for standard ESS users (not is_new_hire, not bank_exceptions/admin/hr): '
  '  • Must submit on or before the 15th. '
  '  • effective_from must be exactly the 1st of the current month (mig 299). '
  'Country-mandatory fields: IND→branch_name+IFSC, LKA→branch_name+branch_code, PAK/SAU→IBAN. '
  '  • branch_name guard added in mig 301. '
  'Exempt roles (bank_exceptions, admin, hr) bypass all date rules. '
  'New hires bypass all date rules.';


-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT count(*)
    FROM   pg_constraint
    WHERE  conname = 'chk_bank_branch_name_required_for_ind_lka'
      AND  conrelid = 'employee_bank_accounts'::regclass
  ) = 1, 'chk_bank_branch_name_required_for_ind_lka not found after migration 301';

  ASSERT (
    SELECT count(*) FROM pg_proc WHERE proname = 'upsert_bank_account'
  ) >= 1, 'upsert_bank_account not found after migration 301';

  RAISE NOTICE 'Migration 301 verified: branch_name CHECK + RPC guard in place.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 301
--
-- Post-migration:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
--   (No schema-shape changes — function signature unchanged — but follow the
--   convention.)
-- =============================================================================
