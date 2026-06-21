-- =============================================================================
-- Migration 350 — Add workflow approver access path to set-snapshot READ RPCs
-- =============================================================================
--
-- BUG
-- ───
-- get_employee_bank_account_set and get_employee_dependent_set both raise
-- "Access denied" when an approver opens the WorkflowReview full view for a
-- pending hire. The approver has an active workflow_task for the employee but
-- neither function's access guard includes "caller is an active task assignee
-- on a workflow instance for this employee."
--
-- The hire pipeline guard (user_can('bank_accounts','view',NULL) AND
-- user_can('hire_employee','view',NULL) AND status IN Pending/Draft/Incomplete)
-- only works if the HR Head role has bank_accounts.view with NULL scope. In
-- practice the role may have it scoped to a target group — so even a correctly
-- configured HR Head can be locked out when reviewing a Draft/Pending hire.
--
-- FIX
-- ───
-- Add to both functions:
--
--   OR EXISTS (
--     SELECT 1 FROM workflow_tasks wt
--     JOIN   workflow_instances wi ON wi.id = wt.instance_id
--     WHERE  wi.record_id   = p_employee_id
--       AND  wt.assigned_to = auth.uid()
--       AND  wt.status      = 'pending'
--   )
--
-- This mirrors the guard already used in update_hire_field (mig 335/347):
-- any user with a live pending task on a workflow instance tied to this
-- employee's record_id may read the bank and dependent set data.
--
-- SCOPE
-- ─────
-- Only the access guard block is changed. All SELECT / JOIN / RETURN logic
-- is identical to mig 329 (bank) and mig 322 (dependents).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_employee_bank_account_set
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_bank_account_set(UUID, DATE);

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
    -- Mig 350: workflow approver path — active task assignee on this record
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks     wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
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
        'attachments',           '[]'::jsonb
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
GRANT EXECUTE ON FUNCTION get_employee_bank_account_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_bank_account_set(UUID, DATE) IS
  'Returns the bank account set active on p_as_of for an employee, with items. '
  'Mig 329: initial. Mig 350: added workflow approver access path.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_employee_dependent_set
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_dependent_set(UUID, DATE);

CREATE OR REPLACE FUNCTION get_employee_dependent_set(
  p_employee_id UUID,
  p_as_of       DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_set_row   employee_dependent_set%ROWTYPE;
  v_items     JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'view', p_employee_id)
    OR (
      user_can('dependents', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id
          AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
    -- Mig 350: workflow approver path — active task assignee on this record
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks     wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_set_row
  FROM employee_dependent_set
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
        'id',                  i.id,
        'dependent_code',      i.dependent_code,
        'relationship_type',   i.relationship_type,
        'dependent_name',      i.dependent_name,
        'date_of_birth',       i.date_of_birth,
        'gender',              i.gender,
        'insurance_eligible',  i.insurance_eligible,
        'attachments', COALESCE(
          (
            SELECT jsonb_agg(jsonb_build_object(
              'id',                 a.id,
              'document_type',      a.document_type,
              'file_name',          a.file_name,
              'original_file_name', a.original_file_name,
              'file_path',          a.file_path,
              'mime_type',          a.mime_type,
              'file_size',          a.file_size,
              'uploaded_at',        a.uploaded_at
            ) ORDER BY a.uploaded_at)
            FROM employee_dependent_attachments a
            WHERE a.dependent_code = i.dependent_code
              AND a.is_active IS NOT FALSE
          ),
          '[]'::jsonb
        )
      )
      ORDER BY i.dependent_code
    ),
    '[]'::jsonb
  )
    INTO v_items
  FROM employee_dependent_item i
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

REVOKE ALL ON FUNCTION get_employee_dependent_set(UUID, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_dependent_set(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION get_employee_dependent_set(UUID, DATE) IS
  'Returns the dependent set active on p_as_of for an employee, with items '
  'and per-item attachments. '
  'Mig 302: initial. Mig 350: added workflow approver access path.';
