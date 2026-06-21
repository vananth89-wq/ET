-- =============================================================================
-- Migration 287 — Add approver workflow-task write access to upsert_bank_account
-- =============================================================================
--
-- Migration 286 added the initiator (awaiting_clarification) path to
-- upsert_bank_account but was applied before the approver path was included.
--
-- Problem: user_can('bank_accounts', 'edit', p_employee_id) fails for pending
-- new-hire employees because they are not yet in the active target-group scope.
-- The approver has bank_accounts.edit in their permission set but the target
-- group query excludes employees with status = 'pending'.
--
-- Fix: mirror the same workflow-task check that get_employee_bank_accounts
-- already uses for read access — if the caller has a pending workflow_task
-- for this employee's hire, grant write access too.
-- =============================================================================

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
