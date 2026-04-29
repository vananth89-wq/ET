-- =============================================================================
-- Expense → Workflow Engine Migration
--
-- Replaces the hardcoded two-step approval (submit_expense / approve_expense /
-- reject_expense / recall_expense) with the generic workflow engine.
--
-- Changes:
--   1. submit_expense()  — rewritten as a thin wrapper around wf_submit()
--                          Validates ownership + draft status, sets submitted_at,
--                          then hands off to the engine.
--   2. recall_expense()  — rewritten to find the in-progress instance and call
--                          wf_withdraw().
--   3. wf_withdraw_by_record() — new convenience RPC: withdraw by module/record
--                          (used when the caller only has the record id, not the
--                          workflow instance id).
--   4. approve_expense() / reject_expense() — DROPPED. Approval now flows
--                          through the Approver Inbox using wf_approve() /
--                          wf_reject(). The old RPCs are removed to prevent
--                          accidental use of the legacy path.
--   5. wf_sync_module_status() — updated to also set submitted_at when the
--                          status transitions to 'submitted', so the expense
--                          report header always shows the correct submission
--                          timestamp.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. submit_expense() — wrapper for wf_submit
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION submit_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id uuid;
  v_status text;
BEGIN
  -- Must be linked to an employee
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  -- Report must exist and belong to the caller
  SELECT status::text INTO v_status
  FROM   expense_reports
  WHERE  id = p_report_id AND deleted_at IS NULL
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

  -- Stamp submitted_at before handing off (wf_sync_module_status sets status
  -- but not submitted_at, so we set it here)
  UPDATE expense_reports
  SET    submitted_at = now(),
         updated_at   = now()
  WHERE  id = p_report_id;

  -- Hand off to the workflow engine
  -- wf_submit() will: create the instance, create the first task,
  -- send notifications, and call wf_sync_module_status → sets status='submitted'
  PERFORM wf_submit(
    p_template_code => 'EXPENSE_APPROVAL',
    p_module_code   => 'expense_reports',
    p_record_id     => p_report_id,
    p_metadata      => '{}'::jsonb
  );
END;
$$;

COMMENT ON FUNCTION submit_expense(uuid) IS
  'Submits an expense report into the workflow engine. '
  'Validates ownership and draft status, stamps submitted_at, '
  'then delegates to wf_submit(EXPENSE_APPROVAL).';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_withdraw_by_record() — convenience RPC: withdraw by module + record id
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_withdraw_by_record(
  p_module_code text,
  p_record_id   uuid,
  p_reason      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance_id uuid;
BEGIN
  -- Find the active (in_progress) instance for this record
  SELECT id INTO v_instance_id
  FROM   workflow_instances
  WHERE  module_code = p_module_code
    AND  record_id   = p_record_id
    AND  status      = 'in_progress'
  ORDER  BY created_at DESC
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active workflow instance found for this record.';
  END IF;

  PERFORM wf_withdraw(v_instance_id, p_reason);
END;
$$;

COMMENT ON FUNCTION wf_withdraw_by_record(text, uuid, text) IS
  'Withdraws the active workflow instance for a module record. '
  'Convenience wrapper around wf_withdraw() for callers that only have '
  'the record id (not the instance id).';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. recall_expense() — wrapper for wf_withdraw_by_record
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION recall_expense(
  p_report_id uuid,
  p_reason    text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id uuid;
BEGIN
  -- Must be linked to an employee
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  -- Must own the report
  PERFORM 1 FROM expense_reports
  WHERE id = p_report_id AND employee_id = v_emp_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense report not found or you do not own it.';
  END IF;

  -- Delegate to the generic withdraw-by-record helper
  -- wf_withdraw() internally checks that auth.uid() is the submitter
  PERFORM wf_withdraw_by_record('expense_reports', p_report_id, p_reason);
END;
$$;

COMMENT ON FUNCTION recall_expense(uuid, text) IS
  'Withdraws (recalls) a submitted expense report from the workflow engine. '
  'Validates ownership then delegates to wf_withdraw_by_record().';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. DROP approve_expense() and reject_expense()
--    Approval now goes through the Approver Inbox → wf_approve() / wf_reject()
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS approve_expense(uuid, text);
DROP FUNCTION IF EXISTS reject_expense(uuid, text);


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Update wf_sync_module_status — stamp submitted_at and reset it on withdraw
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_module_code = 'expense_reports' THEN
    UPDATE expense_reports
    SET
      status       = p_status::expense_status,
      -- Reset submitted_at when report is withdrawn back to draft
      submitted_at = CASE
                       WHEN p_status = 'draft' THEN NULL
                       ELSE submitted_at         -- preserve existing value
                     END,
      updated_at   = now()
    WHERE id = p_record_id;

  -- ── Add further modules here as they are onboarded ──────────────────────
  -- ELSIF p_module_code = 'leave_requests' THEN
  --   UPDATE leave_requests SET status = p_status, updated_at = now()
  --   WHERE id = p_record_id;

  ELSE
    RAISE NOTICE 'wf_sync_module_status: unknown module_code %, record unchanged', p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates the status column on the source module record after a workflow event. '
  'For expense_reports: also clears submitted_at when withdrawn back to draft. '
  'Add a new ELSIF branch for each module you onboard.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, pronargs
FROM   pg_proc
WHERE  proname IN (
  'submit_expense', 'recall_expense',
  'wf_withdraw_by_record', 'wf_sync_module_status'
)
ORDER BY proname;

-- Confirm old RPCs are gone
SELECT COUNT(*) AS legacy_rpcs_remaining
FROM   pg_proc
WHERE  proname IN ('approve_expense', 'reject_expense');
