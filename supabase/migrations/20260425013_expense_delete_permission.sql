-- =============================================================================
-- Expense Delete Permission
--
-- Changes:
--   1. Add expense.delete permission
--   2. Assign to ess (own draft) and admin (any draft) roles
--   3. delete_expense_report(p_report_id) — SECURITY DEFINER RPC
--      Soft-deletes by setting deleted_at. Enforces:
--        • caller has expense.delete permission
--        • report is in draft status (submitted reports must be recalled first)
--        • caller owns the report (unless admin)
-- =============================================================================


-- ── Step 1: Register the permission ──────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id)
SELECT
  'expense.delete',
  'Delete Expense',
  'Delete own draft expense reports. Admins can delete any draft report.',
  m.id
FROM modules m
WHERE m.code = 'expense'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description;


-- ── Step 2: Assign to roles ───────────────────────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.code = 'expense.delete'
WHERE r.code IN ('ess', 'admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── Step 3: delete_expense_report() RPC ──────────────────────────────────────
--
-- Uses SECURITY DEFINER so it can bypass RLS and set deleted_at directly,
-- after performing its own permission + ownership + status checks.
-- Admins can delete any draft; ESS can only delete their own drafts.

CREATE OR REPLACE FUNCTION delete_expense_report(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status      text;
  v_employee_id uuid;
  v_my_emp_id   uuid;
BEGIN
  -- Permission check
  IF NOT (has_role('admin') OR has_permission('expense.delete')) THEN
    RAISE EXCEPTION 'Permission denied: expense.delete required.';
  END IF;

  -- Fetch current report state
  SELECT status::text, employee_id
  INTO v_status, v_employee_id
  FROM expense_reports
  WHERE id = p_report_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found.';
  END IF;

  -- Only draft reports can be deleted (submitted must be recalled first)
  IF v_status != 'draft' THEN
    RAISE EXCEPTION 'Only draft reports can be deleted. Recall the report first if it has been submitted.';
  END IF;

  -- Non-admins can only delete their own reports
  IF NOT has_role('admin') THEN
    v_my_emp_id := get_my_employee_id();
    IF v_employee_id IS DISTINCT FROM v_my_emp_id THEN
      RAISE EXCEPTION 'Permission denied: you can only delete your own expense reports.';
    END IF;
  END IF;

  -- Soft-delete: set deleted_at timestamp
  UPDATE expense_reports
  SET deleted_at = now(),
      updated_at = now()
  WHERE id = p_report_id;
END;
$$;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT p.code, p.name,
  array_agg(r.code ORDER BY r.code) AS assigned_roles
FROM permissions p
JOIN role_permissions rp ON rp.permission_id = p.id
JOIN roles r ON r.id = rp.role_id
WHERE p.code = 'expense.delete'
GROUP BY p.code, p.name;
