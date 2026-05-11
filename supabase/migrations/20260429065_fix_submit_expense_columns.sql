-- =============================================================================
-- Migration 065: Fix submit_expense — wrong column names in metadata query
--
-- Two bugs introduced in migration 038/045:
--
--   1. line_items.expense_report_id  → line_items.report_id
--      (column was always report_id; expense_report_id never existed)
--
--   2. expense_reports.currency_id   → expense_reports.base_currency_id
--      (column was renamed to base_currency_id in the initial schema)
--
-- Both caused submit_expense() to throw a SQL error on every submit attempt.
-- The SECURITY DEFINER function raised an exception, useExpenseData caught it,
-- reverted the optimistic status patch, and the report stayed in draft.
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id          uuid;
  v_status          text;
  v_metadata        jsonb;
  v_wf_template_id  uuid;
  v_template_code   text;
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

  -- ── Resolve workflow dynamically ──────────────────────────────────────────
  v_wf_template_id := resolve_workflow_for_submission('expense_reports', auth.uid());

  IF v_wf_template_id IS NULL THEN
    RAISE EXCEPTION
      'No active workflow assignment found for expense_reports. '
      'Please ask your administrator to configure a workflow assignment.';
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_wf_template_id;

  -- ── Build metadata snapshot ───────────────────────────────────────────────
  -- FIX 1: line_items.report_id   (was: expense_report_id — column never existed)
  -- FIX 2: er.base_currency_id    (was: er.currency_id — wrong name)
  SELECT jsonb_build_object(
    'total_amount',  COALESCE(
                       (SELECT SUM(amount)
                        FROM   line_items
                        WHERE  report_id  = p_report_id   -- ← fixed
                          AND  deleted_at IS NULL),
                       0
                     ),
    'currency_id',   er.base_currency_id,                 -- ← fixed
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

  -- Delegate to the generic workflow engine with resolved template
  PERFORM wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'expense_reports',
    p_record_id     => p_report_id,
    p_metadata      => v_metadata
  );
END;
$$;

COMMENT ON FUNCTION submit_expense(uuid) IS
  'Submits an expense report into the workflow engine. '
  'Dynamically resolves the workflow template via resolve_workflow_for_submission(). '
  'Fixed in migration 065: line_items.report_id and er.base_currency_id.';


-- VERIFICATION
SELECT proname, prosrc LIKE '%report_id%' AS uses_report_id,
       prosrc LIKE '%base_currency_id%'   AS uses_base_currency_id
FROM   pg_proc
WHERE  proname = 'submit_expense';
