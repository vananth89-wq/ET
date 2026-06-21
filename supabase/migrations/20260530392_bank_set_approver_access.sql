-- =============================================================================
-- Migration 392 — get_employee_bank_account_set: add workflow task access path
-- =============================================================================
-- Approvers viewing a hire workflow task hit "access denied" because the RPC
-- only allows super_admin, scoped bank_accounts.view/edit, self-ESS, or the
-- hire-pipeline path (hire_employee.view + bank_accounts.view global).
-- Approvers holding a pending task should also be able to read the bank set.
-- Same pattern as upsert_employment_info Path D.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_bank_account_set(
  p_employee_id UUID,
  p_as_of       DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_set_row employee_bank_account_set%ROWTYPE;
  v_items   JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'view', p_employee_id)
    OR user_can('bank_accounts', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
    OR (
      user_can('bank_accounts', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
    -- Path D: approver holds a pending workflow task for this employee
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    -- Path E: initiator whose request was sent back (needs to view while editing)
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RAISE EXCEPTION 'get_employee_bank_account_set: access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_set_row
  FROM employee_bank_account_set
  WHERE employee_id    = p_employee_id
    AND is_active      = true
    AND effective_from <= p_as_of
    AND effective_to   >= p_as_of
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_set_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'set', NULL, 'items', '[]'::jsonb);
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',                    i.id,
        'bank_account_group_id', i.bank_account_group_id,
        'country_code',          i.country_code,
        'currency_code',         i.currency_code,
        'bank_name',             i.bank_name,
        'branch_name',           i.branch_name,
        'branch_code',           i.branch_code,
        'account_holder_name',   i.account_holder_name,
        'account_number',        i.account_number,
        'ifsc_code',             i.ifsc_code,
        'iban',                  i.iban,
        'swift_bic',             i.swift_bic,
        'is_primary',            i.is_primary,
        'attachments', (
          SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
              'file_name',    a.file_name,
              'file_type',    a.file_type,
              'file_size',    a.file_size,
              'storage_path', a.storage_path
            )
            ORDER BY a.uploaded_at
          ), '[]'::jsonb)
          FROM employee_bank_attachments a
          WHERE a.bank_account_item_id = i.id
            AND a.is_active = true
        )
      )
      ORDER BY i.is_primary DESC, i.bank_name
    ),
    '[]'::jsonb
  )
    INTO v_items
  FROM employee_bank_account_item i
  WHERE i.set_id = v_set_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'set', jsonb_build_object(
      'id',             v_set_row.id,
      'employee_id',    v_set_row.employee_id,
      'effective_from', v_set_row.effective_from,
      'effective_to',   v_set_row.effective_to,
      'is_active',      v_set_row.is_active,
      'created_at',     v_set_row.created_at
    ),
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION get_employee_bank_account_set(UUID, DATE) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_bank_account_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_bank_account_set(UUID, DATE) IS
  'Mig 392: added workflow task access path (Path D) so approvers holding a '
  'pending task for an employee can read their bank set during hire review.';
