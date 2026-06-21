-- =============================================================================
-- Migration 284 — Fix wrong column name in get_employee_bank_accounts
-- =============================================================================
--
-- Migration 283 used wt.assignee_employee_id which does not exist.
-- The correct column is workflow_tasks.assigned_to (uuid referencing profiles/auth.users).
-- Compared against auth.uid() (not get_my_employee_id() which returns employee uuid).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_bank_accounts(
  p_employee_id    uuid,
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
    SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY r.is_active DESC, r.effective_from DESC), '[]'::jsonb)
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
