-- =============================================================================
-- Fix submit_expense — populate metadata snapshot for conditional routing
--
-- The original submit_expense passed '{}' as metadata to wf_submit, meaning
-- workflow_step_conditions could never evaluate against real values.
--
-- This patch rebuilds submit_expense to snapshot the expense report fields
-- at submission time so that skip conditions work correctly:
--
--   total_amount   numeric  — sum of line items in base currency
--   currency_id    text     — report currency
--   dept_id        text     — submitting employee's department UUID
--   work_country   text     — employee's work country
--   employee_id    text     — submitting employee UUID
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id     uuid;
  v_status     text;
  v_metadata   jsonb;
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

  -- ── Build metadata snapshot ───────────────────────────────────────────────
  -- Captures key fields at submission time so workflow_step_conditions can
  -- evaluate against a stable snapshot even if the report is later edited.
  SELECT jsonb_build_object(
    'total_amount',  COALESCE(
                       (SELECT SUM(amount) FROM line_items
                        WHERE expense_report_id = p_report_id
                          AND deleted_at IS NULL),
                       0
                     ),
    'currency_id',   er.currency_id,
    'dept_id',       e.dept_id::text,
    'work_country',  e.work_country,
    'employee_id',   e.id::text
  )
  INTO v_metadata
  FROM expense_reports er
  JOIN employees       e  ON e.id = er.employee_id
  WHERE er.id = p_report_id;

  -- Stamp submitted_at before handing off
  UPDATE expense_reports
  SET    submitted_at = now(),
         updated_at   = now()
  WHERE  id = p_report_id;

  -- Delegate to the generic workflow engine with real metadata
  PERFORM wf_submit(
    p_template_code => 'EXPENSE_APPROVAL',
    p_module_code   => 'EXPENSE',
    p_record_id     => p_report_id,
    p_metadata      => v_metadata
  );
END;
$$;

COMMENT ON FUNCTION submit_expense(uuid) IS
  'Submits an expense report into the workflow engine. '
  'Snapshots total_amount, currency_id, dept_id, work_country, employee_id '
  'into the workflow instance metadata so skip conditions evaluate correctly.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname, prosrc LIKE '%v_metadata%' AS has_metadata_snapshot
FROM   pg_proc
WHERE  proname = 'submit_expense';
