-- Migration 189: Add expense report name to workflow metadata snapshot
-- ─────────────────────────────────────────────────────────────────────────────
-- Problem: submit_expense builds the metadata snapshot without the expense
-- report's name, so the Approver Inbox shows the workflow template name
-- ("Expense Report Approval") instead of the actual report name
-- ("Reeshetha May Expense Part 2").
--
-- Fix:
--   1. Rebuild submit_expense to include 'name' in the jsonb snapshot.
--   2. Backfill existing workflow_instances so already-submitted reports
--      also show their name in the inbox.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_expense(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wf_template_id  uuid;
  v_template_code   text;
  v_metadata        jsonb;
BEGIN
  -- Resolve the active workflow template for this submission
  SELECT wf_template_id
  INTO   v_wf_template_id
  FROM   resolve_workflow_for_submission(auth.uid(), 'expense_reports')
  LIMIT 1;

  IF v_wf_template_id IS NULL THEN
    RAISE EXCEPTION 'submit_expense: no active workflow template found for expense_reports';
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_wf_template_id;

  -- ── Build metadata snapshot ───────────────────────────────────────────────
  -- FIX 1 (065): report_id               (was: expense_report_id)
  -- FIX 2 (065): er.base_currency_id     (was: er.currency_id)
  -- FIX 3 (067): SUM(converted_amount)   (was: SUM(amount))
  -- FIX 4 (067): currency_code           (new: ISO code from currencies table)
  -- FIX 5 (189): name                    (new: expense report name for inbox display)
  SELECT jsonb_build_object(
    'name',          er.name,                                    -- ← new (189)
    'total_amount',  COALESCE(
                       (SELECT SUM(converted_amount)
                        FROM   line_items
                        WHERE  report_id  = p_report_id
                          AND  deleted_at IS NULL),
                       0
                     ),
    'currency_id',   er.base_currency_id,
    'currency_code', c.code,
    'dept_id',       e.dept_id::text,
    'work_country',  e.work_country,
    'employee_id',   e.id::text
  )
  INTO v_metadata
  FROM expense_reports er
  JOIN employees       e  ON e.id  = er.employee_id
  JOIN currencies      c  ON c.id  = er.base_currency_id
  WHERE er.id = p_report_id;

  -- Stamp submitted_at before handing off
  UPDATE expense_reports
  SET    submitted_at = now(),
         updated_at   = now()
  WHERE  id = p_report_id;

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
  'Fixed 065: line_items.report_id and er.base_currency_id. '
  'Fixed 067: SUM(converted_amount), currency_code ISO field. '
  'Fixed 189: name field added so Approver Inbox shows report name not template name.';

-- ── Backfill existing workflow instances ──────────────────────────────────────
-- For expense_reports instances already in progress, stamp the report name
-- into their metadata so the inbox shows it without a re-submission.

UPDATE workflow_instances wi
SET    metadata = wi.metadata || jsonb_build_object('name', er.name)
FROM   expense_reports er
WHERE  wi.module_code = 'expense_reports'
  AND  wi.record_id   = er.id
  AND  (wi.metadata->>'name') IS NULL;  -- only rows that don't already have it
