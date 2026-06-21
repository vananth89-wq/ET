-- =============================================================================
-- Migration 282 — Fix permission codes in RLS policies and RPCs
-- =============================================================================
--
-- Migrations 273 and 275 reference the OLD permission codes:
--   employee.view_bank_accounts  (deleted by migration 280)
--   employee.edit_bank_accounts  (deleted by migration 280)
--
-- The current codes are:
--   bank_accounts.view
--   bank_accounts.edit
--
-- has_permission() and user_can() look up by code string, so any call
-- using the old codes now returns false — ESS employees can't read or
-- write their own bank accounts.
--
-- FIX: Recreate the RLS policies and RPCs with correct codes.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Fix RLS policies on employee_bank_accounts
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "bank_accounts_select" ON employee_bank_accounts;
DROP POLICY IF EXISTS "bank_accounts_insert" ON employee_bank_accounts;
DROP POLICY IF EXISTS "bank_accounts_update" ON employee_bank_accounts;

CREATE POLICY "bank_accounts_select" ON employee_bank_accounts
  FOR SELECT USING (
    user_can('bank_accounts', 'view', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.view')
    )
  );

CREATE POLICY "bank_accounts_insert" ON employee_bank_accounts
  FOR INSERT WITH CHECK (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.edit')
    )
  );

CREATE POLICY "bank_accounts_update" ON employee_bank_accounts
  FOR UPDATE USING (
    user_can('bank_accounts', 'edit', employee_id)
    OR (
      employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.edit')
    )
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Fix RLS policies on employee_bank_attachments
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "bank_attachments_select" ON employee_bank_attachments;
DROP POLICY IF EXISTS "bank_attachments_insert" ON employee_bank_attachments;
DROP POLICY IF EXISTS "bank_attachments_update" ON employee_bank_attachments;

CREATE POLICY "bank_attachments_select" ON employee_bank_attachments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_bank_accounts ba
      WHERE ba.id = bank_account_id
        AND (
          user_can('bank_accounts', 'view', ba.employee_id)
          OR (ba.employee_id = get_my_employee_id() AND has_permission('bank_accounts.view'))
        )
    )
  );

CREATE POLICY "bank_attachments_insert" ON employee_bank_attachments
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_bank_accounts ba
      WHERE ba.id = bank_account_id
        AND (
          user_can('bank_accounts', 'edit', ba.employee_id)
          OR (ba.employee_id = get_my_employee_id() AND has_permission('bank_accounts.edit'))
        )
    )
  );

CREATE POLICY "bank_attachments_update" ON employee_bank_attachments
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_bank_accounts ba
      WHERE ba.id = bank_account_id
        AND (
          user_can('bank_accounts', 'edit', ba.employee_id)
          OR (ba.employee_id = get_my_employee_id() AND has_permission('bank_accounts.edit'))
        )
    )
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Fix get_employee_bank_accounts RPC access guard
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_employee_bank_accounts(
  p_employee_id    uuid,
  p_include_history boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Access guard: HR/admin via target group OR employee viewing their own
  IF NOT (
    user_can('bank_accounts', 'view', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.view')
    )
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN (
    SELECT jsonb_agg(row_to_json(r) ORDER BY r.is_active DESC, r.effective_from DESC)
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
        ba.is_active,
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
          WHERE att.bank_account_id = ba.id),
          '[]'::jsonb
        ) AS attachments
      FROM employee_bank_accounts ba
      WHERE ba.employee_id = p_employee_id
        AND (p_include_history OR ba.is_active)
    ) r
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Fix upsert_bank_account RPC access guard
-- ─────────────────────────────────────────────────────────────────────────────

-- Only patch the access guard lines — recreate with corrected codes
-- (The full function body is reproduced to replace the old one)
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
    -- Amend: close the current active row
    UPDATE employee_bank_accounts
    SET    effective_to = p_effective_from - interval '1 day',
           is_active    = false
    WHERE  bank_account_group_id = p_bank_account_group_id
      AND  is_active = true;
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
    is_primary, effective_from, effective_to, is_active
  ) VALUES (
    p_employee_id, v_group_id,
    p_country_code, p_currency_code, p_bank_name,
    p_branch_name, p_branch_code, p_account_holder_name,
    p_account_number, p_ifsc_code, p_iban, p_swift_bic,
    p_is_primary, p_effective_from, '9999-12-31', true
  )
  RETURNING id INTO v_account_id;

  -- ── 4. If primary, demote all other accounts ──────────────────────────────────
  IF p_is_primary THEN
    UPDATE employee_bank_accounts
    SET    is_primary = false
    WHERE  employee_id = p_employee_id
      AND  id <> v_account_id
      AND  is_active = true;
  END IF;

  -- ── 5. Save attachments ───────────────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
  LOOP
    INSERT INTO employee_bank_attachments (
      bank_account_id, file_name, file_type, file_size, storage_path
    ) VALUES (
      v_account_id,
      v_att->>'file_name',
      v_att->>'file_type',
      (v_att->>'file_size')::bigint,
      v_att->>'storage_path'
    )
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'bank_account_id', v_account_id);
END;
$$;
