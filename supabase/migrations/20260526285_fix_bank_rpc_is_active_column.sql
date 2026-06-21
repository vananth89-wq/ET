-- =============================================================================
-- Migration 285 — Fix is_active column references in bank account RPCs
-- =============================================================================
--
-- employee_bank_accounts has NO is_active column.
-- Active rows are identified by: effective_to = '9999-12-31'
-- is_active exists only on employee_bank_attachments.
--
-- This migration fixes all RPCs that incorrectly reference ba.is_active:
--   • get_employee_bank_accounts — SELECT, WHERE, ORDER BY
--   • upsert_bank_account        — UPDATE SET, UPDATE WHERE x2, INSERT columns
--
-- The computed column (ba.effective_to = '9999-12-31') AS is_active is returned
-- so the TypeScript BankAccount interface requires no changes.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_employee_bank_accounts
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_employee_bank_accounts(
  p_employee_id     uuid,
  p_include_history boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Access guard:
  --   a) HR/admin via target-group permission
  --   b) ESS employee viewing their own accounts
  --   c) Active workflow task holder for this employee (hire/profile review)
  IF NOT (
    user_can('bank_accounts', 'view', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.view')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN (
    SELECT COALESCE(
      jsonb_agg(row_to_json(r) ORDER BY r.effective_to DESC, r.effective_from DESC),
      '[]'::jsonb
    )
    FROM (
      SELECT
        ba.id,
        ba.bank_account_group_id,
        ba.country_code,
        ba.currency_code,
        ba.bank_name,
        ba.branch_name,
        ba.branch_code,
        ba.account_holder_name,
        ba.account_number,
        ba.ifsc_code,
        ba.iban,
        ba.swift_bic,
        ba.is_primary,
        ba.effective_from,
        ba.effective_to,
        -- Derived active flag: no is_active column, active = effective_to sentinel
        (ba.effective_to = '9999-12-31') AS is_active,
        ba.created_at,
        COALESCE(
          (SELECT jsonb_agg(jsonb_build_object(
            'id',           att.id,
            'file_name',    att.file_name,
            'file_type',    att.file_type,
            'file_size',    att.file_size,
            'storage_path', att.storage_path,
            'uploaded_at',  att.uploaded_at
          ) ORDER BY att.uploaded_at)
          FROM employee_bank_attachments att
          WHERE att.bank_account_id = ba.id
            AND att.is_active = true),
          '[]'::jsonb
        ) AS attachments
      FROM employee_bank_accounts ba
      WHERE ba.employee_id = p_employee_id
        AND (p_include_history OR ba.effective_to = '9999-12-31')
    ) r
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. upsert_bank_account
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_bank_account(
  p_employee_id           uuid,
  p_country_code          text,
  p_currency_code         text,
  p_bank_name             text,
  p_account_holder_name   text,
  p_account_number        text,
  p_effective_from        date,
  p_bank_account_group_id uuid    DEFAULT NULL,
  p_branch_name           text    DEFAULT NULL,
  p_branch_code           text    DEFAULT NULL,
  p_ifsc_code             text    DEFAULT NULL,
  p_iban                  text    DEFAULT NULL,
  p_swift_bic             text    DEFAULT NULL,
  p_is_primary            boolean DEFAULT false,
  p_is_new_hire           boolean DEFAULT false,
  p_attachments           jsonb   DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id   uuid;
  v_account_id uuid;
  v_att        jsonb;
BEGIN
  -- ── 1. Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.edit')
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to edit bank accounts for this employee.');
  END IF;

  -- ── 2. Determine group ────────────────────────────────────────────────────────
  IF p_bank_account_group_id IS NOT NULL THEN
    -- Amend: close the current active row (effective_to = '9999-12-31')
    UPDATE employee_bank_accounts
    SET    effective_to = p_effective_from - interval '1 day'
    WHERE  bank_account_group_id = p_bank_account_group_id
      AND  effective_to          = '9999-12-31';
    v_group_id := p_bank_account_group_id;
  ELSE
    v_group_id := gen_random_uuid();
  END IF;

  -- ── 3. Insert new row ─────────────────────────────────────────────────────────
  INSERT INTO employee_bank_accounts (
    employee_id, bank_account_group_id,
    country_code, currency_code, bank_name,
    branch_name, branch_code, account_holder_name,
    account_number, ifsc_code, iban, swift_bic,
    is_primary, effective_from, effective_to,
    created_by, updated_by
  ) VALUES (
    p_employee_id, v_group_id,
    p_country_code, p_currency_code, p_bank_name,
    p_branch_name, p_branch_code, p_account_holder_name,
    p_account_number, p_ifsc_code, p_iban, p_swift_bic,
    p_is_primary, p_effective_from, '9999-12-31',
    auth.uid(), auth.uid()
  )
  RETURNING id INTO v_account_id;

  -- ── 4. If primary, demote all other active accounts ───────────────────────────
  IF p_is_primary THEN
    UPDATE employee_bank_accounts
    SET    is_primary = false
    WHERE  employee_id   = p_employee_id
      AND  id           <> v_account_id
      AND  effective_to  = '9999-12-31';
  END IF;

  -- ── 5. Save attachments ───────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_bank_attachments (
      bank_account_id, employee_id, file_name, file_type, file_size, storage_path,
      uploaded_by
    ) VALUES (
      v_account_id,
      p_employee_id,
      v_att->>'file_name',
      v_att->>'file_type',
      (v_att->>'file_size')::bigint,
      v_att->>'storage_path',
      auth.uid()
    )
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'bank_account_id', v_account_id);
END;
$$;
