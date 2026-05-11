-- =============================================================================
-- Migration 067: Fix submit_expense metadata snapshot
--
-- Two gaps in the metadata built by submit_expense():
--
--   1. total_amount used SUM(amount) — the raw per-currency amount on each
--      line item.  For multi-currency reports this produces a nonsensical mix
--      of currencies summed together (e.g. 25 USD + 800 INR = 825, meaningless).
--      The correct field is SUM(converted_amount) — every line item already
--      stores the amount converted to the report's base currency.
--
--   2. currency_code was missing from the snapshot.  The approver inbox and
--      any downstream workflow rules that need to display or threshold-check
--      the total need the ISO currency code (e.g. "INR"), not just the UUID
--      stored in base_currency_id.  Added by joining currencies on
--      er.base_currency_id.
--
-- Impact analysis:
--   • Only submit_expense() is changed — no other function is touched.
--   • The metadata JSONB is written into workflow_instances.metadata at
--     submission time.  Existing submitted/approved/rejected instances keep
--     their old snapshot; only new submissions get the corrected values.
--   • currency_id UUID key is kept in the snapshot for backwards compatibility
--     with any existing queries that read it.
--   • The new currency_code key is additive — no existing consumer breaks.
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
  -- FIX 1 (065): report_id               (was: expense_report_id — column never existed)
  -- FIX 2 (065): er.base_currency_id     (was: er.currency_id — wrong name)
  -- FIX 3 (067): SUM(converted_amount)   (was: SUM(amount) — mixed-currency sum)
  -- FIX 4 (067): currency_code added     (new: ISO code resolved from currencies table)
  SELECT jsonb_build_object(
    'total_amount',  COALESCE(
                       (SELECT SUM(converted_amount)          -- ← fixed (067): base-currency total
                        FROM   line_items
                        WHERE  report_id  = p_report_id
                          AND  deleted_at IS NULL),
                       0
                     ),
    'currency_id',   er.base_currency_id,                    -- kept for backwards compat
    'currency_code', c.code,                                  -- ← new (067): ISO code e.g. "INR"
    'dept_id',       e.dept_id::text,
    'work_country',  e.work_country,
    'employee_id',   e.id::text
  )
  INTO v_metadata
  FROM expense_reports er
  JOIN employees       e  ON e.id  = er.employee_id
  JOIN currencies      c  ON c.id  = er.base_currency_id     -- ← new join (067)
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
  'Fixed in migration 065: line_items.report_id and er.base_currency_id. '
  'Fixed in migration 067: total_amount uses SUM(converted_amount) for correct '
  'base-currency totals; currency_code ISO text field added to metadata snapshot.';


-- VERIFICATION
SELECT
  proname,
  prosrc LIKE '%converted_amount%'  AS uses_converted_amount,
  prosrc LIKE '%currency_code%'     AS includes_currency_code,
  prosrc LIKE '%JOIN currencies%'   AS joins_currencies
FROM pg_proc
WHERE proname = 'submit_expense';
