-- =============================================================================
-- Update submit_expense to use resolve_workflow_for_submission()
--
-- Previously submit_expense hardcoded p_template_code => 'EXPENSE_APPROVAL'.
-- This migration replaces that with a dynamic lookup via the new resolver so
-- that workflow assignment configuration in the admin UI is honoured.
--
-- Also fixes the module_code inconsistency:
--   Old: p_module_code => 'EXPENSE'   (did not match template's module_code)
--   New: p_module_code => 'expense_reports' (matches workflow_templates.module_code)
--
-- Finally, seeds the initial GLOBAL assignment for the expense_reports module
-- so existing data continues to work after this migration is applied.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Seed GLOBAL assignment for expense_reports
--          (must run BEFORE updating submit_expense)
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_assignments (
  module_code,
  wf_template_id,
  assignment_type,
  entity_id,
  priority,
  effective_from,
  effective_to,
  is_active,
  created_by
)
SELECT
  'expense_reports',
  t.id,
  'GLOBAL',
  NULL,
  0,
  CURRENT_DATE,
  NULL,     -- open-ended
  true,
  NULL      -- system seed
FROM workflow_templates t
WHERE t.code      = 'EXPENSE_APPROVAL'
  AND t.is_active = true
ORDER BY t.version DESC
LIMIT 1
ON CONFLICT DO NOTHING;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Rebuild submit_expense using the dynamic resolver
-- ════════════════════════════════════════════════════════════════════════════

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

  -- ── Resolve workflow dynamically ─────────────────────────────────────────────
  v_wf_template_id := resolve_workflow_for_submission('expense_reports', auth.uid());

  IF v_wf_template_id IS NULL THEN
    RAISE EXCEPTION
      'No active workflow assignment found for expense_reports. '
      'Please ask your administrator to configure a workflow assignment.';
  END IF;

  -- Look up the template code (wf_submit expects the code, not the UUID)
  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_wf_template_id;

  -- ── Build metadata snapshot ───────────────────────────────────────────────────
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
  'Dynamically resolves the workflow template via resolve_workflow_for_submission() '
  'so admin UI changes to workflow assignments are honoured without code changes. '
  'Snapshots total_amount, currency_id, dept_id, work_country, employee_id '
  'into the workflow instance metadata so skip conditions evaluate correctly.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — Fix wf_submit module_code guard
--
-- wf_submit previously enforced: template.module_code = p_module_code.
-- The template uses 'expense_reports'; old code passed 'EXPENSE'.
-- Now that submit_expense passes 'expense_reports' this will pass, but
-- we update the guard message to be clearer just in case.
-- ════════════════════════════════════════════════════════════════════════════
-- No code change needed in wf_submit — the module_code values now match.


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — Verification
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm seed assignment exists
SELECT wa.module_code, wa.assignment_type, wt.code AS template_code,
       wa.effective_from, wa.is_active
FROM   workflow_assignments wa
JOIN   workflow_templates   wt ON wt.id = wa.wf_template_id
WHERE  wa.module_code = 'expense_reports';

-- Confirm function updated
SELECT proname,
       prosrc LIKE '%resolve_workflow_for_submission%' AS uses_resolver
FROM   pg_proc
WHERE  proname = 'submit_expense';
