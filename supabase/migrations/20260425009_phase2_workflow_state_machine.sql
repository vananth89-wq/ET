-- =============================================================================
-- Phase 2: Expense Workflow State Machine
--
-- ⚠️  IMPORTANT — run this in TWO steps in the Supabase SQL Editor:
--
--   STEP 1: Run only the ALTER TYPE block below (lines 24-26).
--           This commits the new enum value before anything uses it.
--
--   STEP 2: Run the rest of the file (everything after line 26).
--
-- Why: PostgreSQL will not let you USE a new enum value (even in a function
-- body) in the same transaction that ADDs it. Running the ALTER TYPE first
-- as a standalone statement commits the enum change, making 'manager_approved'
-- available for all subsequent statements.
--
-- Changes:
--   1. Add 'manager_approved' to expense_status enum         ← STEP 1
--   2. Create expense_approvals audit table                  ← STEP 2
--   3. submit_expense()  — ESS: draft → submitted
--   4. approve_expense() — two-stage approval
--        Manager/DeptHead: submitted → manager_approved
--        Finance/Admin:    manager_approved → approved
--   5. reject_expense()  — reject at any approval stage
--   6. recall_expense()  — ESS: submitted → draft
--   7. RLS on expense_approvals
--   8. Update expense_reports UPDATE policy
-- =============================================================================


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1 — Run this block alone first, then commit / execute before Step 2
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TYPE expense_status ADD VALUE IF NOT EXISTS 'manager_approved' AFTER 'submitted';


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2 — Run after Step 1 has been committed
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Step 2: expense_approvals audit table ────────────────────────────────────

CREATE TABLE IF NOT EXISTS expense_approvals (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id   uuid        NOT NULL REFERENCES expense_reports(id) ON DELETE CASCADE,
  profile_id  uuid        NOT NULL REFERENCES profiles(id),
  action      text        NOT NULL CHECK (action IN ('submitted','manager_approved','approved','rejected','recalled')),
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS expense_approvals_report_idx  ON expense_approvals(report_id);
CREATE INDEX IF NOT EXISTS expense_approvals_profile_idx ON expense_approvals(profile_id);

ALTER TABLE expense_approvals ENABLE ROW LEVEL SECURITY;


-- ── Step 3: submit_expense() ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id  uuid;
  v_status  text;          -- text avoids same-txn enum issues
BEGIN
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  SELECT status::text INTO v_status
  FROM expense_reports
  WHERE id = p_report_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found.';
  END IF;

  PERFORM 1 FROM expense_reports
  WHERE id = p_report_id AND employee_id = v_emp_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not own this expense report.';
  END IF;

  IF v_status != 'draft' THEN
    RAISE EXCEPTION 'Only draft reports can be submitted (current status: %).', v_status;
  END IF;

  UPDATE expense_reports
  SET status       = 'submitted',
      submitted_at = now(),
      updated_at   = now()
  WHERE id = p_report_id;

  INSERT INTO expense_approvals (report_id, profile_id, action)
  VALUES (p_report_id, auth.uid(), 'submitted');
END;
$$;


-- ── Step 4: approve_expense() ────────────────────────────────────────────────
--
-- v_new_status is declared as TEXT (not expense_status) so the function body
-- does not reference the new enum value at compile time — only at runtime,
-- after the enum change has already been committed.

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
  v_report_status       text;          -- text: avoids same-txn enum restriction
  v_new_status          text;          -- text: assigned 'manager_approved' at runtime
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

  -- Resolve approver's employee UUID for approved_by / rejected_by columns
  SELECT employee_id INTO v_approver_emp_id
  FROM   profiles
  WHERE  id = auth.uid();

  -- ── Determine transition ────────────────────────────────────────────────────

  IF has_role('admin') THEN
    IF v_report_status NOT IN ('submitted', 'manager_approved') THEN
      RAISE EXCEPTION 'Report cannot be approved in its current state: %.', v_report_status;
    END IF;
    v_new_status := 'approved';
    v_action     := 'approved';

  ELSIF has_permission('expense.view_org') THEN
    IF v_report_status != 'manager_approved' THEN
      RAISE EXCEPTION 'Finance can only approve manager-approved reports (current status: %).', v_report_status;
    END IF;
    v_new_status := 'approved';
    v_action     := 'approved';

  ELSIF has_permission('expense.view_team') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Manager/Dept Head can only approve submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT (
      is_my_direct_report(v_report_employee_id)
      OR is_in_my_department(v_report_employee_id)
    ) THEN
      RAISE EXCEPTION 'This employee is not within your approval scope.';
    END IF;
    v_new_status := 'manager_approved';
    v_action     := 'manager_approved';

  ELSE
    RAISE EXCEPTION 'You do not have permission to approve expense reports.';
  END IF;

  -- ── Execute transition ──────────────────────────────────────────────────────
  -- Cast v_new_status back to expense_status — safe because the enum value
  -- was committed in Step 1 before this function runs.

  UPDATE expense_reports
  SET status      = v_new_status::expense_status,
      approved_at = CASE WHEN v_new_status = 'approved' THEN now()              ELSE approved_at END,
      approved_by = CASE WHEN v_new_status = 'approved' THEN v_approver_emp_id  ELSE approved_by END,
      updated_at  = now()
  WHERE id = p_report_id;

  INSERT INTO expense_approvals (report_id, profile_id, action, notes)
  VALUES (p_report_id, auth.uid(), v_action, p_notes);
END;
$$;


-- ── Step 5: reject_expense() ─────────────────────────────────────────────────

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
  FROM   profiles
  WHERE  id = auth.uid();

  IF has_role('admin') THEN
    IF v_report_status NOT IN ('submitted', 'manager_approved') THEN
      RAISE EXCEPTION 'Cannot reject a report in state: %.', v_report_status;
    END IF;

  ELSIF has_permission('expense.view_org') THEN
    IF v_report_status != 'manager_approved' THEN
      RAISE EXCEPTION 'Finance can only reject manager-approved reports (current status: %).', v_report_status;
    END IF;

  ELSIF has_permission('expense.view_team') THEN
    IF v_report_status != 'submitted' THEN
      RAISE EXCEPTION 'Manager/Dept Head can only reject submitted reports (current status: %).', v_report_status;
    END IF;
    IF NOT (
      is_my_direct_report(v_report_employee_id)
      OR is_in_my_department(v_report_employee_id)
    ) THEN
      RAISE EXCEPTION 'This employee is not within your approval scope.';
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


-- ── Step 6: recall_expense() ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recall_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id uuid;
  v_status text;
BEGIN
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  SELECT status::text INTO v_status
  FROM expense_reports
  WHERE id = p_report_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found.';
  END IF;

  PERFORM 1 FROM expense_reports
  WHERE id = p_report_id AND employee_id = v_emp_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not own this expense report.';
  END IF;

  IF v_status != 'submitted' THEN
    RAISE EXCEPTION 'Only submitted reports can be recalled (current status: %).', v_status;
  END IF;

  UPDATE expense_reports
  SET status       = 'draft',
      submitted_at = NULL,
      updated_at   = now()
  WHERE id = p_report_id;

  INSERT INTO expense_approvals (report_id, profile_id, action, notes)
  VALUES (p_report_id, auth.uid(), 'recalled', 'Recalled by employee');
END;
$$;


-- ── Step 7: RLS on expense_approvals ─────────────────────────────────────────

DROP POLICY IF EXISTS expense_approvals_select ON expense_approvals;

CREATE POLICY expense_approvals_select ON expense_approvals FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE er.id = expense_approvals.report_id
        AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')  AND er.status::text != 'draft')
          OR (has_permission('expense.view_team') AND er.status::text != 'draft'
              AND (is_my_direct_report(er.employee_id) OR is_in_my_department(er.employee_id)))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );


-- ── Step 8: Update expense_reports UPDATE policy ──────────────────────────────

DROP POLICY IF EXISTS expense_reports_update ON expense_reports;

CREATE POLICY expense_reports_update ON expense_reports FOR UPDATE
  USING (
    has_role('admin')
    OR (has_permission('expense.view_org')
        AND status::text IN ('submitted', 'manager_approved', 'approved', 'rejected'))
    OR (has_permission('expense.view_team')
        AND status::text IN ('submitted', 'manager_approved', 'rejected')
        AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id)))
    OR (employee_id = get_my_employee_id()
        AND status::text IN ('draft', 'rejected'))
  )
  WITH CHECK (
    has_role('admin')
    OR (has_permission('expense.view_org')
        AND status::text IN ('submitted', 'manager_approved', 'approved', 'rejected'))
    OR (has_permission('expense.view_team')
        AND status::text IN ('submitted', 'manager_approved', 'rejected')
        AND (is_my_direct_report(employee_id) OR is_in_my_department(employee_id)))
    OR (employee_id = get_my_employee_id()
        AND status::text IN ('draft', 'rejected'))
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT unnest(enum_range(NULL::expense_status)) AS status_value;

SELECT proname, prosecdef
FROM pg_proc
WHERE proname IN ('submit_expense','approve_expense','reject_expense','recall_expense')
ORDER BY proname;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'expense_approvals'
ORDER BY ordinal_position;
