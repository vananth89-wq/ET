-- =============================================================================
-- Phase 4: In-App Notifications
--
-- Changes:
--   1. Create notifications table + RLS
--   2. Trigger function: trg_expense_workflow_notify()
--      Fires AFTER INSERT on expense_approvals, routes notifications to the
--      right users based on the workflow action.
--   3. Trigger: after_expense_approval_notify
--
-- Notification routing:
--   submitted        → employee's direct manager + current dept head
--   manager_approved → all Finance + Admin users
--   approved         → the expense report owner (employee)
--   rejected         → the expense report owner (employee)
--   recalled         → no notification (employee did it themselves)
-- =============================================================================


-- ── Step 1: notifications table ───────────────────────────────────────────────
-- Drop any stale/partial definition from a previous run attempt.

DROP TABLE IF EXISTS notifications CASCADE;

CREATE TABLE notifications (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id  uuid        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title       text        NOT NULL,
  body        text,
  link        text,        -- frontend route e.g. /expense/report/<uuid>
  is_read     boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Fast lookup: a user's unread notifications ordered newest first
CREATE INDEX notifications_profile_unread_idx
  ON notifications(profile_id, is_read, created_at DESC);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Users can only see their own notifications
DROP POLICY IF EXISTS notifications_select ON notifications;
CREATE POLICY notifications_select ON notifications FOR SELECT
  USING (profile_id = auth.uid());

-- Users can only mark their own notifications as read (UPDATE is_read only)
DROP POLICY IF EXISTS notifications_update ON notifications;
CREATE POLICY notifications_update ON notifications FOR UPDATE
  USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());

-- INSERT is blocked at the row level — only the SECURITY DEFINER trigger inserts
-- (no policy needed; absence of INSERT policy = deny)


-- ── Step 2: Notification trigger function ────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_expense_workflow_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report_name   text;
  v_employee_id   uuid;
  v_emp_name      text;
  v_manager_id    uuid;
  v_dept_id       uuid;
  v_emp_profile   uuid;
  v_link          text;
BEGIN
  -- Fetch report header + employee details in one query
  SELECT
    er.name,
    er.employee_id,
    e.name,
    e.manager_id,
    e.dept_id
  INTO
    v_report_name,
    v_employee_id,
    v_emp_name,
    v_manager_id,
    v_dept_id
  FROM expense_reports er
  JOIN employees e ON e.id = er.employee_id
  WHERE er.id = NEW.report_id;

  IF NOT FOUND THEN RETURN NEW; END IF;

  -- Employee's own profile (for approved/rejected notifications)
  SELECT id INTO v_emp_profile
  FROM profiles
  WHERE employee_id = v_employee_id AND is_active = true
  LIMIT 1;

  v_link := '/expense/report/' || NEW.report_id::text;

  -- ── Route by action ────────────────────────────────────────────────────────

  IF NEW.action = 'submitted' THEN
    -- Notify direct manager (if any)
    IF v_manager_id IS NOT NULL THEN
      INSERT INTO notifications (profile_id, title, body, link)
      SELECT p.id,
        'New expense report submitted',
        v_emp_name || ' submitted "' || v_report_name || '" and it needs your approval.',
        v_link
      FROM profiles p
      WHERE p.employee_id = v_manager_id
        AND p.is_active   = true
        AND p.id         != NEW.profile_id   -- don't notify the submitter
      LIMIT 1;
    END IF;

    -- Notify current dept head (skip if they are also the direct manager)
    IF v_dept_id IS NOT NULL THEN
      INSERT INTO notifications (profile_id, title, body, link)
      SELECT DISTINCT p.id,
        'New expense report submitted',
        v_emp_name || ' submitted "' || v_report_name || '" and it needs your approval.',
        v_link
      FROM department_heads dh
      JOIN employees dh_emp ON dh_emp.id = dh.employee_id
      JOIN profiles p ON p.employee_id = dh_emp.id AND p.is_active = true
      WHERE dh.department_id = v_dept_id
        AND (dh.to_date IS NULL OR dh.to_date >= CURRENT_DATE)
        AND dh_emp.id  IS DISTINCT FROM v_manager_id  -- not already notified above
        AND p.id      != NEW.profile_id;
    END IF;

  ELSIF NEW.action = 'manager_approved' THEN
    -- Notify all Finance + Admin users (excluding the person who just approved)
    INSERT INTO notifications (profile_id, title, body, link)
    SELECT DISTINCT ur.profile_id,
      'Expense report ready for final approval',
      v_emp_name || '''s "' || v_report_name || '" has been manager-approved and needs Finance sign-off.',
      v_link
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id AND r.code IN ('finance', 'admin')
    WHERE ur.is_active   = true
      AND ur.profile_id != NEW.profile_id;   -- exclude the approver

  ELSIF NEW.action = 'approved' THEN
    -- Notify the employee whose report was approved
    IF v_emp_profile IS NOT NULL AND v_emp_profile != NEW.profile_id THEN
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (
        v_emp_profile,
        'Expense report approved ✓',
        '"' || v_report_name || '" has been fully approved.',
        v_link
      );
    END IF;

  ELSIF NEW.action = 'rejected' THEN
    -- Notify the employee whose report was rejected
    IF v_emp_profile IS NOT NULL AND v_emp_profile != NEW.profile_id THEN
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (
        v_emp_profile,
        'Expense report rejected',
        '"' || v_report_name || '" was rejected. Reason: ' ||
          COALESCE(NEW.notes, 'No reason provided.'),
        v_link
      );
    END IF;

  -- recalled → no notification (employee withdrew their own report)
  END IF;

  RETURN NEW;
END;
$$;


-- ── Step 3: Attach trigger to expense_approvals ───────────────────────────────
-- Guard: only create the trigger if expense_approvals exists (Phase 2 must be run first).

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'expense_approvals'
  ) THEN
    DROP TRIGGER IF EXISTS after_expense_approval_notify ON expense_approvals;

    CREATE TRIGGER after_expense_approval_notify
    AFTER INSERT ON expense_approvals
    FOR EACH ROW
    EXECUTE FUNCTION trg_expense_workflow_notify();
  ELSE
    RAISE NOTICE 'expense_approvals table not found — run Phase 2 migration first, then re-run this script.';
  END IF;
END
$$;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'notifications'
ORDER BY ordinal_position;

SELECT trigger_name, event_object_table, event_manipulation, action_timing
FROM information_schema.triggers
WHERE trigger_name = 'after_expense_approval_notify';
