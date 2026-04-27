-- =============================================================================
-- Drop MSS Role + Expense Permission Redesign
--
-- Changes:
--   1. Reassign MSS users → Manager, deactivate MSS role
--   2. Update sync_system_roles() — remove MSS block
--   3. Add is_in_my_department() — dept_head scope helper
--   4. Remove expense.approve, expense.final_approve permissions
--   5. Add expense.view_org, expense.edit_approval permissions
--   6. Rebuild expense role_permissions matrix
--   7. Rebuild RLS on expense_reports, line_items, attachments
--      (dept_head now uses department scope, not direct-report scope)
-- =============================================================================


-- ── Step 1: Reassign MSS → Manager ───────────────────────────────────────────
-- Grant Manager to anyone with MSS who doesn't already have it.

INSERT INTO user_roles (profile_id, role_id, granted_by, is_active, assignment_source, granted_at)
SELECT
  ur.profile_id,
  (SELECT id FROM roles WHERE code = 'manager'),
  ur.granted_by,
  true,
  'manual',
  now()
FROM user_roles ur
JOIN roles r ON r.id = ur.role_id AND r.code = 'mss'
WHERE ur.is_active = true
  AND NOT EXISTS (
    SELECT 1 FROM user_roles ur2
    JOIN roles r2 ON r2.id = ur2.role_id AND r2.code = 'manager'
    WHERE ur2.profile_id = ur.profile_id AND ur2.is_active = true
  )
ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true, updated_at = now();

-- Soft-deactivate all MSS user_role assignments
UPDATE user_roles
SET is_active = false, updated_at = now()
WHERE role_id = (SELECT id FROM roles WHERE code = 'mss');

-- Deactivate the MSS role itself
UPDATE roles SET active = false WHERE code = 'mss';


-- ── Step 2: Update sync_system_roles() — remove MSS block ────────────────────
-- Manager is now manually assigned by admin. Only ESS and dept_head are
-- system-synced from employee data.

CREATE OR REPLACE FUNCTION sync_system_roles(p_profile_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile   RECORD;
  v_emp       RECORD;
  v_ess_id    uuid;
  v_dh_id     uuid;
  v_inserted  integer := 0;
  v_removed   integer := 0;
BEGIN
  SELECT id INTO v_ess_id FROM roles WHERE code = 'ess';
  SELECT id INTO v_dh_id  FROM roles WHERE code = 'dept_head';

  FOR v_profile IN
    SELECT p.id, p.employee_id
    FROM   profiles p
    WHERE  (p_profile_id IS NULL OR p.id = p_profile_id)
      AND  p.is_active = true
  LOOP
    IF v_profile.employee_id IS NULL THEN CONTINUE; END IF;

    SELECT * INTO v_emp FROM employees WHERE id = v_profile.employee_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- ── ESS: every active employee gets ESS ──────────────────────────────────
    INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
    VALUES (v_profile.id, v_ess_id, 'system', true, now())
    ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
    v_inserted := v_inserted + 1;

    -- ── Department Head: driven by department_heads table ────────────────────
    IF EXISTS (
      SELECT 1 FROM department_heads
      WHERE employee_id = v_emp.id
        AND (to_date IS NULL OR to_date >= CURRENT_DATE)
    ) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_dh_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles SET is_active = false, updated_at = now()
      WHERE  profile_id       = v_profile.id
        AND  role_id          = v_dh_id
        AND  assignment_source = 'system';
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('synced', v_inserted, 'revoked', v_removed);
END;
$$;


-- ── Step 3: is_in_my_department() — dept_head scope helper ───────────────────
-- Returns true if emp_id belongs to a department the current user currently heads.
-- Used in expense RLS to give dept_head full department visibility.

CREATE OR REPLACE FUNCTION is_in_my_department(emp_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   employees e
    JOIN   department_heads dh ON dh.department_id = e.dept_id
    WHERE  e.id             = emp_id
      AND  dh.employee_id   = get_my_employee_id()
      AND  (dh.to_date IS NULL OR dh.to_date >= CURRENT_DATE)
  );
$$;


-- ── Step 4: Remove old expense permissions ────────────────────────────────────

DELETE FROM role_permissions
WHERE permission_id IN (
  SELECT id FROM permissions WHERE code IN ('expense.approve', 'expense.final_approve')
);

DELETE FROM permissions
WHERE code IN ('expense.approve', 'expense.final_approve');


-- ── Step 5: Add new expense permissions ──────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id)
SELECT p.code, p.name, p.description,
  (SELECT id FROM modules WHERE code = 'expense')
FROM (VALUES
  ('expense.view_org',
   'View All Expenses',
   'View expense reports across the entire organisation (Finance sign-off scope)'),
  ('expense.edit_approval',
   'Edit on Approval Page',
   'Edit expense data during the approval process — add GL codes, notes, adjustments')
) AS p(code, name, description)
ON CONFLICT (code) DO NOTHING;


-- ── Step 6: Rebuild expense role_permissions matrix ──────────────────────────

-- Clear all current expense role_permissions
DELETE FROM role_permissions
WHERE permission_id IN (
  SELECT id FROM permissions WHERE code LIKE 'expense.%'
);

-- Rebuild from agreed matrix:
--
--   expense.create        → ESS, Admin
--   expense.submit        → ESS, Admin
--   expense.view_own      → ESS, Admin
--   expense.edit          → ESS, Admin          (own draft editing)
--   expense.view_team     → Manager, DeptHead   (DB scopes by role)
--   expense.view_org      → Finance, Admin      (entire org)
--   expense.edit_approval → Finance, Admin      (approval page fields)
--   expense.export        → Finance, Admin

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('ess',       'expense.create'),
  ('ess',       'expense.submit'),
  ('ess',       'expense.view_own'),
  ('ess',       'expense.edit'),
  ('manager',   'expense.view_team'),
  ('dept_head', 'expense.view_team'),
  ('finance',   'expense.view_org'),
  ('finance',   'expense.edit_approval'),
  ('finance',   'expense.export'),
  ('admin',     'expense.create'),
  ('admin',     'expense.submit'),
  ('admin',     'expense.view_own'),
  ('admin',     'expense.edit'),
  ('admin',     'expense.view_team'),
  ('admin',     'expense.view_org'),
  ('admin',     'expense.edit_approval'),
  ('admin',     'expense.export')
) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT DO NOTHING;


-- ── Step 7: Rebuild expense RLS policies ─────────────────────────────────────

DROP POLICY IF EXISTS expense_reports_select ON expense_reports;
DROP POLICY IF EXISTS expense_reports_insert ON expense_reports;
DROP POLICY IF EXISTS expense_reports_update ON expense_reports;
DROP POLICY IF EXISTS expense_reports_delete ON expense_reports;

DROP POLICY IF EXISTS line_items_select ON line_items;
DROP POLICY IF EXISTS line_items_insert ON line_items;
DROP POLICY IF EXISTS line_items_update ON line_items;
DROP POLICY IF EXISTS line_items_delete ON line_items;

DROP POLICY IF EXISTS attachments_select ON attachments;
DROP POLICY IF EXISTS attachments_insert ON attachments;
DROP POLICY IF EXISTS attachments_update ON attachments;
DROP POLICY IF EXISTS attachments_delete ON attachments;


-- ── EXPENSE REPORTS ───────────────────────────────────────────────────────────
--
-- Visibility scopes:
--   Admin      → everything (all statuses including draft)
--   Finance    → all org, submitted+ only
--   Manager    → direct reports, submitted+ only     (is_my_direct_report)
--   Dept Head  → full department, submitted+ only    (is_in_my_department)  ← fixed
--   ESS        → own reports only

CREATE POLICY expense_reports_select ON expense_reports FOR SELECT
  USING (
    deleted_at IS NULL AND (
      has_role('admin')
      OR (has_role('finance')   AND status != 'draft')
      OR (has_role('manager')   AND status != 'draft' AND is_my_direct_report(employee_id))
      OR (has_role('dept_head') AND status != 'draft' AND is_in_my_department(employee_id))
      OR employee_id = get_my_employee_id()
    )
  );

CREATE POLICY expense_reports_insert ON expense_reports FOR INSERT
  WITH CHECK (employee_id = get_my_employee_id());

-- UPDATE:
--   ESS        → own draft or rejected reports
--   Manager    → direct report submitted/approved/rejected
--   Dept Head  → department submitted/approved/rejected
--   Finance    → any submitted/approved/rejected
--   Admin      → anything
CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_role('finance')   AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_role('manager')   AND status IN ('submitted', 'approved', 'rejected') AND is_my_direct_report(employee_id))
    OR (has_role('dept_head') AND status IN ('submitted', 'approved', 'rejected') AND is_in_my_department(employee_id))
    OR (employee_id = get_my_employee_id() AND status IN ('draft', 'rejected'))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_role('finance')   AND status IN ('submitted', 'approved', 'rejected'))
    OR (has_role('manager')   AND status IN ('submitted', 'approved', 'rejected') AND is_my_direct_report(employee_id))
    OR (has_role('dept_head') AND status IN ('submitted', 'approved', 'rejected') AND is_in_my_department(employee_id))
    OR (employee_id = get_my_employee_id() AND status IN ('draft', 'rejected'))
  );

CREATE POLICY expense_reports_delete ON expense_reports FOR DELETE
  USING (has_role('admin'));


-- ── LINE ITEMS ────────────────────────────────────────────────────────────────

CREATE POLICY line_items_select ON line_items FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = line_items.report_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance')   AND er.status != 'draft')
          OR (has_role('manager')   AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR (has_role('dept_head') AND er.status != 'draft' AND is_in_my_department(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY line_items_insert ON line_items FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY line_items_update ON line_items FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY line_items_delete ON line_items FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id        = line_items.report_id
        AND er.status    = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );


-- ── ATTACHMENTS ───────────────────────────────────────────────────────────────

CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_role('finance')   AND er.status != 'draft')
          OR (has_role('manager')   AND er.status != 'draft' AND is_my_direct_report(er.employee_id))
          OR (has_role('dept_head') AND er.status != 'draft' AND is_in_my_department(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

CREATE POLICY attachments_insert ON attachments FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY attachments_update ON attachments FOR UPDATE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  )
  WITH CHECK (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );

CREATE POLICY attachments_delete ON attachments FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status      = 'draft'
        AND er.employee_id = get_my_employee_id()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

-- Roles: MSS should show active = false
SELECT code, name, active, sort_order FROM roles ORDER BY sort_order;

-- Expense permissions with assigned roles
SELECT
  p.code,
  p.name,
  COALESCE(array_agg(r.code ORDER BY r.sort_order) FILTER (WHERE r.code IS NOT NULL), '{}') AS assigned_roles
FROM permissions p
LEFT JOIN role_permissions rp ON rp.permission_id = p.id
LEFT JOIN roles r ON r.id = rp.role_id
WHERE p.code LIKE 'expense.%'
GROUP BY p.code, p.name
ORDER BY p.code;
