-- =============================================================================
-- Split expense.view_team → expense.view_direct + expense.view_team
--
-- Problem:
--   expense.view_team was assigned to both Manager and DeptHead, with RLS
--   relying on OR(is_my_direct_report, is_in_my_department). This conflates
--   two different scopes and becomes ambiguous for VPs / deep hierarchies.
--
-- Solution:
--   expense.view_direct  → 1-level only (immediate direct reports)
--                          Assigned to: manager
--   expense.view_team    → full org subtree, recursive downward
--                          Assigned to: dept_head, admin
--   Admin gains both; Manager loses view_team and gains view_direct.
--
-- DB changes:
--   1. New helper: is_in_my_org_subtree(emp_id) — recursive CTE
--   2. New permission row: expense.view_direct
--   3. role_permissions: reassign manager → view_direct; dept_head keeps view_team
--   4. Re-drop and recreate RLS policies on expense_reports, line_items,
--      attachments, workflow_instances that referenced expense.view_team
-- =============================================================================


-- ── 1. is_in_my_org_subtree() ─────────────────────────────────────────────────
--
-- Returns TRUE if emp_id is anywhere below the current user in the management
-- chain (direct report, or their reports, etc.).
--
-- Walks DOWN the tree: starts from the caller's direct reports, then their
-- direct reports, until no more levels exist.
--
-- STABLE + SECURITY DEFINER: same pattern as is_my_direct_report().

CREATE OR REPLACE FUNCTION is_in_my_org_subtree(emp_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH RECURSIVE subtree AS (
    -- Base case: immediate direct reports of the current user
    SELECT id
    FROM   employees
    WHERE  manager_id = get_my_employee_id()
      AND  deleted_at IS NULL

    UNION ALL

    -- Recursive case: reports of reports
    SELECT e.id
    FROM   employees e
    JOIN   subtree   s ON e.manager_id = s.id
    WHERE  e.deleted_at IS NULL
  )
  SELECT EXISTS (SELECT 1 FROM subtree WHERE id = emp_id);
$$;

COMMENT ON FUNCTION is_in_my_org_subtree(uuid) IS
  'Returns true if emp_id falls anywhere in the current user''s downward org '
  'subtree (direct reports and all their descendants). STABLE + SECURITY '
  'DEFINER: evaluated once per query, bypasses RLS on employees.';


-- ── 2. Register expense.view_direct permission ────────────────────────────────

INSERT INTO permissions (code, name, description, module_id)
SELECT
  'expense.view_direct',
  'View Direct Report Expenses',
  'View expense reports submitted by immediate direct reports (1 level only).',
  m.id
FROM modules m
WHERE m.code = 'expense'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description;


-- ── 3. Update role_permissions ────────────────────────────────────────────────
--
-- Manager:   remove expense.view_team → add expense.view_direct
-- DeptHead:  keep expense.view_team (now means full recursive subtree)
-- Admin:     keep expense.view_team, add expense.view_direct

-- Remove view_team from manager
DELETE FROM role_permissions
WHERE role_id      = (SELECT id FROM roles WHERE code = 'manager')
  AND permission_id = (SELECT id FROM permissions WHERE code = 'expense.view_team');

-- Add view_direct to manager
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r, permissions p
WHERE  r.code = 'manager'
  AND  p.code = 'expense.view_direct'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Add view_direct to admin (admin keeps view_team too)
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r, permissions p
WHERE  r.code = 'admin'
  AND  p.code = 'expense.view_direct'
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── 4. Recreate affected RLS policies ─────────────────────────────────────────
--
-- We only touch the policies that referenced expense.view_team.
-- All other policies remain unchanged.

-- ── expense_reports SELECT ────────────────────────────────────────────────────
--
-- Scope ladder (most permissive first so Postgres short-circuits):
--   Admin          → all, including drafts
--   expense.view_org  → all submitted+ (Finance, HR)
--   expense.view_team → full subtree submitted+ (DeptHead and above)
--   expense.view_direct → direct reports submitted+ (Manager)
--   expense.view_own  → own reports only (ESS)

DROP POLICY IF EXISTS expense_reports_select ON expense_reports;

CREATE POLICY expense_reports_select ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_role('admin')
      OR (has_permission('expense.view_org')
            AND status != 'draft')
      OR (has_permission('expense.view_team')
            AND status != 'draft'
            AND is_in_my_org_subtree(employee_id))
      OR (has_permission('expense.view_direct')
            AND status != 'draft'
            AND is_my_direct_report(employee_id))
      OR (has_permission('expense.view_own')
            AND employee_id = get_my_employee_id())
    )
  );


-- ── expense_reports UPDATE ────────────────────────────────────────────────────

DROP POLICY IF EXISTS expense_reports_update ON expense_reports;

CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_permission('expense.edit')
          AND employee_id = get_my_employee_id()
          AND status IN ('draft', 'rejected'))
    OR (has_permission('expense.view_org') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected'))
    OR (has_permission('expense.view_team') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected')
          AND is_in_my_org_subtree(employee_id))
    OR (has_permission('expense.view_direct') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected')
          AND is_my_direct_report(employee_id))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_permission('expense.edit')
          AND employee_id = get_my_employee_id()
          AND status IN ('draft', 'rejected'))
    OR (has_permission('expense.view_org') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected'))
    OR (has_permission('expense.view_team') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected')
          AND is_in_my_org_subtree(employee_id))
    OR (has_permission('expense.view_direct') AND has_permission('expense.edit_approval')
          AND status IN ('submitted', 'manager_approved', 'rejected')
          AND is_my_direct_report(employee_id))
  );


-- ── line_items SELECT ─────────────────────────────────────────────────────────

DROP POLICY IF EXISTS line_items_select ON line_items;

CREATE POLICY line_items_select ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = line_items.report_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')
                AND er.status != 'draft')
          OR (has_permission('expense.view_team')
                AND er.status != 'draft'
                AND is_in_my_org_subtree(er.employee_id))
          OR (has_permission('expense.view_direct')
                AND er.status != 'draft'
                AND is_my_direct_report(er.employee_id))
          OR (has_permission('expense.view_own')
                AND er.employee_id = get_my_employee_id())
        )
    )
  );


-- ── attachments SELECT ────────────────────────────────────────────────────────

DROP POLICY IF EXISTS attachments_select ON attachments;

CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')
                AND er.status != 'draft')
          OR (has_permission('expense.view_team')
                AND er.status != 'draft'
                AND is_in_my_org_subtree(er.employee_id))
          OR (has_permission('expense.view_direct')
                AND er.status != 'draft'
                AND is_my_direct_report(er.employee_id))
          OR (has_permission('expense.view_own')
                AND er.employee_id = get_my_employee_id())
        )
    )
  );


-- ── workflow_instances SELECT ─────────────────────────────────────────────────

DROP POLICY IF EXISTS workflow_instances_select ON workflow_instances;

CREATE POLICY workflow_instances_select ON workflow_instances FOR SELECT
  USING (
    has_permission('expense.view_org')
    OR has_permission('expense.view_team')
    OR has_permission('expense.view_direct')
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT p.code, p.name,
  array_agg(r.code ORDER BY r.code) AS assigned_roles
FROM permissions p
JOIN role_permissions rp ON rp.permission_id = p.id
JOIN roles r ON r.id = rp.role_id AND r.active = true
WHERE p.code IN ('expense.view_direct', 'expense.view_team', 'expense.view_org')
GROUP BY p.code, p.name
ORDER BY p.code;
