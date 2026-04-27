-- =============================================================================
-- Fix Manager Role: System-Synced + Workflow RPC Gaps
--
-- Problems fixed:
--
--   1. Manager role was reclassified to 'custom' (migration 016) — wrong.
--      Manager should be a SYSTEM role, auto-assigned by sync_system_roles()
--      to anyone who is a manager_id for at least one active employee.
--      (Mirrors how MSS worked before it was dropped in migration 007.)
--
--   2. sync_system_roles() (migration 007) removed the manager block entirely.
--      Re-add it: assign manager role when employee has direct reports,
--      revoke it when they have none.
--
--   3. approve_expense() and reject_expense() (migration 009) check
--      has_permission('expense.view_team') for the manager-level approval
--      branch. After migration 014, Manager has expense.view_direct (not
--      view_team). Managers cannot approve — fixed by splitting the branch.
--
--   4. expense_approvals SELECT policy (migration 009) only covers view_team.
--      Managers with view_direct cannot see the approval audit trail — fixed.
--
-- Changes:
--   1. Restore manager role as role_type='system', is_system=true, editable=false
--   2. Rebuild sync_system_roles() with manager block
--   3. Rebuild approve_expense() with view_direct + view_team branches
--   4. Rebuild reject_expense() with view_direct + view_team branches
--   5. Recreate expense_approvals SELECT policy with view_direct branch
-- =============================================================================


-- ── 1. Restore manager as a system role ───────────────────────────────────────

UPDATE roles
SET role_type   = 'system',
    is_system   = true,
    editable    = false,
    description = 'Team management — expense approvals and direct report visibility. Auto-assigned to employees who manage at least one direct report.',
    sort_order  = 4
WHERE code = 'manager';


-- ── 2. Rebuild sync_system_roles() ───────────────────────────────────────────
--
-- Assigns system roles based on employee data:
--   ESS       → every active employee
--   Manager   → employees who are manager_id for ≥1 active employee
--   DeptHead  → employees listed in department_heads (with active to_date)
--
-- Passing p_profile_id scopes the sync to a single user (used by the
-- post-save trigger). Omitting it syncs everyone.

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
  v_mgr_id    uuid;
  v_dh_id     uuid;
  v_inserted  integer := 0;
  v_removed   integer := 0;
BEGIN
  SELECT id INTO v_ess_id FROM roles WHERE code = 'ess';
  SELECT id INTO v_mgr_id FROM roles WHERE code = 'manager';
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

    -- ── ESS: every active employee ───────────────────────────────────────────
    INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
    VALUES (v_profile.id, v_ess_id, 'system', true, now())
    ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
    v_inserted := v_inserted + 1;

    -- ── Manager: employee has at least one active direct report ──────────────
    IF EXISTS (
      SELECT 1 FROM employees sub
      WHERE  sub.manager_id = v_emp.id
        AND  sub.deleted_at IS NULL
    ) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_mgr_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles
      SET    is_active  = false,
             updated_at = now()
      WHERE  profile_id        = v_profile.id
        AND  role_id           = v_mgr_id
        AND  assignment_source = 'system';
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

    -- ── DeptHead: listed in department_heads with active date range ──────────
    IF EXISTS (
      SELECT 1 FROM department_heads
      WHERE  employee_id = v_emp.id
        AND  (to_date IS NULL OR to_date >= CURRENT_DATE)
    ) THEN
      INSERT INTO user_roles (profile_id, role_id, assignment_source, is_active, granted_at)
      VALUES (v_profile.id, v_dh_id, 'system', true, now())
      ON CONFLICT (profile_id, role_id) DO UPDATE SET is_active = true;
      v_inserted := v_inserted + 1;
    ELSE
      UPDATE user_roles
      SET    is_active  = false,
             updated_at = now()
      WHERE  profile_id        = v_profile.id
        AND  role_id           = v_dh_id
        AND  assignment_source = 'system';
      GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('synced', v_inserted, 'revoked', v_removed);
END;
$$;


-- ── 3. Rebuild approve_expense() ─────────────────────────────────────────────
--
-- Approval branch order:
--   Admin         → any submitted or manager_approved → approved (skip stage)
--   Finance/HR    → manager_approved only             → approved
--   DeptHead      → submitted only, org subtree scope → manager_approved
--   Manager       → submitted only, direct-report scope → manager_approved

CREATE OR REPLACE FUNCTION approve_expense(
  p_report_id uuid,
  p_notes     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report_employee_id  uuid;
  v_report_status       text;
  v_new_status          text;
  v_action              text;
  v_approver_emp_id     uuid;
BEGIN
  -- Lock + fetch
  SELECT employee_id, status::text
  INTO   v_report_employee_id, v_report_status
  FROM   expense_reports
  WHERE  id = p_report_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found.';
  END IF;

  SELECT employee_id INTO v_approver_emp_id
  FROM   profiles WHERE id = auth.uid();

  -- ── Admin: approve at any stage, jump straight to approved ───────────────
  IF has_role('admin') THEN
    IF v_report_status NOT IN ('submitted', 'manager_approved') THEN
      RAISE EXCEPTION 'Report cannot be approved in its current state: %.', v_report_status;
    END IF;
    v_new_status := 'approved';
    v_action     := 'approved';

  -- ── Finance / HR: final approval (manager_approved → approved) ───────────
  ELSIF has_permission('expense.view_org') THEN
    IF v_report_status != 'manager_approved' THEN
      RAISE EXCEPTION 'Finance can only approve manager-approved reports (current status: %).', v_report_status;
    END IF;
    v_new_status := 'approved';
    v_action     := 'approved';

  -- ── DeptHead: full org subtree (submitted → manager_approved) ────────────
  ELSIF has_permission('expense.view_team') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Department Head can only approve submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT is_in_my_org_subtree(v_report_employee_id) THEN
      RAISE EXCEPTION 'This employee is not within your org subtree.';
    END IF;
    v_new_status := 'manager_approved';
    v_action     := 'manager_approved';

  -- ── Manager: direct reports only (submitted → manager_approved) ──────────
  ELSIF has_permission('expense.view_direct') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Manager can only approve submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT is_my_direct_report(v_report_employee_id) THEN
      RAISE EXCEPTION 'This employee is not your direct report.';
    END IF;
    v_new_status := 'manager_approved';
    v_action     := 'manager_approved';

  ELSE
    RAISE EXCEPTION 'You do not have permission to approve expense reports.';
  END IF;

  UPDATE expense_reports
  SET status      = v_new_status::expense_status,
      approved_at = CASE WHEN v_new_status = 'approved' THEN now()             ELSE approved_at END,
      approved_by = CASE WHEN v_new_status = 'approved' THEN v_approver_emp_id ELSE approved_by END,
      updated_at  = now()
  WHERE id = p_report_id;

  INSERT INTO expense_approvals (report_id, profile_id, action, notes)
  VALUES (p_report_id, auth.uid(), v_action, p_notes);
END;
$$;


-- ── 4. Rebuild reject_expense() ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION reject_expense(
  p_report_id uuid,
  p_reason    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report_employee_id  uuid;
  v_report_status       text;
  v_rejector_emp_id     uuid;
BEGIN
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'A rejection reason is required.';
  END IF;

  SELECT employee_id, status::text
  INTO   v_report_employee_id, v_report_status
  FROM   expense_reports
  WHERE  id = p_report_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found.';
  END IF;

  SELECT employee_id INTO v_rejector_emp_id
  FROM   profiles WHERE id = auth.uid();

  -- ── Admin ─────────────────────────────────────────────────────────────────
  IF has_role('admin') THEN
    IF v_report_status NOT IN ('submitted', 'manager_approved') THEN
      RAISE EXCEPTION 'Cannot reject a report in state: %.', v_report_status;
    END IF;

  -- ── Finance / HR ──────────────────────────────────────────────────────────
  ELSIF has_permission('expense.view_org') THEN
    IF v_report_status != 'manager_approved' THEN
      RAISE EXCEPTION 'Finance can only reject manager-approved reports (current status: %).', v_report_status;
    END IF;

  -- ── DeptHead: full org subtree ────────────────────────────────────────────
  ELSIF has_permission('expense.view_team') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Department Head can only reject submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT is_in_my_org_subtree(v_report_employee_id) THEN
      RAISE EXCEPTION 'This employee is not within your org subtree.';
    END IF;

  -- ── Manager: direct reports only ──────────────────────────────────────────
  ELSIF has_permission('expense.view_direct') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Manager can only reject submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT is_my_direct_report(v_report_employee_id) THEN
      RAISE EXCEPTION 'This employee is not your direct report.';
    END IF;

  ELSE
    RAISE EXCEPTION 'You do not have permission to reject expense reports.';
  END IF;

  UPDATE expense_reports
  SET status           = 'rejected',
      rejected_at      = now(),
      rejected_by      = v_rejector_emp_id,
      rejection_reason = p_reason,
      updated_at       = now()
  WHERE id = p_report_id;

  INSERT INTO expense_approvals (report_id, profile_id, action, notes)
  VALUES (p_report_id, auth.uid(), 'rejected', p_reason);
END;
$$;


-- ── 5. Fix expense_approvals SELECT policy ────────────────────────────────────
--
-- Managers with expense.view_direct were unable to see the approval audit
-- trail for their direct reports' submissions.

DROP POLICY IF EXISTS expense_approvals_select ON expense_approvals;

CREATE POLICY expense_approvals_select ON expense_approvals FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = expense_approvals.report_id
        AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')
                AND er.status::text != 'draft')
          OR (has_permission('expense.view_team')
                AND er.status::text != 'draft'
                AND is_in_my_org_subtree(er.employee_id))
          OR (has_permission('expense.view_direct')
                AND er.status::text != 'draft'
                AND is_my_direct_report(er.employee_id))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Manager role classification
SELECT code, name, role_type, is_system, active, editable, sort_order
FROM   roles
WHERE  code IN ('manager', 'dept_head', 'ess', 'admin')
ORDER  BY sort_order;

-- 2. Run a full sync to populate manager role from employee data
SELECT sync_system_roles(NULL::uuid);

-- 3. Show resulting manager role membership
SELECT u.email, e.name AS employee_name
FROM   user_roles ur
JOIN   roles      r ON r.id = ur.role_id AND r.code = 'manager'
JOIN   profiles   p ON p.id = ur.profile_id
JOIN   auth.users u ON u.id = p.id
LEFT   JOIN employees e ON e.id = p.employee_id
WHERE  ur.is_active = true
ORDER  BY employee_name;
