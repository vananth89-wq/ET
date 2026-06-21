-- =============================================================================
-- Migration 286 — Allow sent-back initiator to read and edit bank accounts
-- =============================================================================
--
-- When an approver sends a hire back for clarification, the workflow instance
-- status becomes 'awaiting_clarification'. The initiator (submitted_by) then
-- edits the hire form and resubmits. They need to read and edit bank accounts
-- during this process.
--
-- The existing access paths cover:
--   a) HR/admin via target-group permission
--   b) ESS employee viewing their own account
--   c) Active pending workflow task holder (approver)
--
-- Missing path: the INITIATOR whose instance is awaiting_clarification.
-- They have no pending workflow_task — the task status at send-back is
-- 'returned_to_initiator' — so check (c) fails for them.
--
-- FIX: Add a fourth path in both RPCs:
--   d) submitted_by = auth.uid() AND wi.status = 'awaiting_clarification'
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_employee_bank_accounts — add initiator read path
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
  --   c) Active workflow task holder (approver reviewing hire)
  --   d) Initiator whose hire was sent back for clarification
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
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
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
-- 2. upsert_bank_account — add approver (pending task) + initiator edit paths
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The approver has bank_accounts.edit in their permission set, but user_can()
-- may fail for pending/new-hire employees who aren't yet in the active target
-- group scope. The workflow task check gives the same write grant as read.
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
  --   a) HR/admin via target-group edit permission
  --   b) ESS employee editing their own account
  --   c) Active workflow task holder (approver with pending task for this hire)
  --   d) Initiator whose hire was sent back for clarification
  IF NOT (
    user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('bank_accounts.edit')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to edit bank accounts for this employee.');
  END IF;

  -- ── 2. Determine group ────────────────────────────────────────────────────────
  IF p_bank_account_group_id IS NOT NULL THEN
    -- Amend: close the current active row
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
