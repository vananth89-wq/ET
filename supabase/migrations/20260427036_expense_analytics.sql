-- =============================================================================
-- Expense Analytics RPCs
--
-- Provides server-side aggregation functions for the Expense Analytics
-- dashboard. All functions are permission-aware via RLS on the underlying
-- tables and accept consistent filter parameters:
--
--   p_date_from   timestamptz  — filter by submitted_at >= this value (NULL = no lower bound)
--   p_date_to     timestamptz  — filter by submitted_at <  this value (NULL = no upper bound)
--   p_dept_id     uuid         — filter to a specific department       (NULL = all)
--   p_employee_id uuid         — filter to a specific employee         (NULL = all)
--
-- Functions:
--   1. rpc_expense_kpis            — headline KPI numbers
--   2. rpc_spend_by_department     — approved spend grouped by department
--   3. rpc_expense_status_funnel   — report count per status
--   4. rpc_monthly_spend_trend     — approved spend per calendar month (last N months)
--   5. rpc_pending_approvals       — list of in-flight reports sorted by age
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. rpc_expense_kpis
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION rpc_expense_kpis(
  p_date_from   timestamptz DEFAULT NULL,
  p_date_to     timestamptz DEFAULT NULL,
  p_dept_id     uuid        DEFAULT NULL,
  p_employee_id uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    -- Total reports submitted in range
    'total_submitted',      COUNT(*)                                          FILTER (WHERE er.submitted_at IS NOT NULL),
    -- Approved reports
    'total_approved',       COUNT(*)                                          FILTER (WHERE er.status = 'approved'),
    -- Rejected reports
    'total_rejected',       COUNT(*)                                          FILTER (WHERE er.status = 'rejected'),
    -- Currently pending (submitted or manager_approved)
    'total_pending',        COUNT(*)                                          FILTER (WHERE er.status IN ('submitted', 'manager_approved')),
    -- Total approved spend (sum of converted line item amounts)
    'approved_spend',       COALESCE(SUM(li_totals.total)                    FILTER (WHERE er.status = 'approved'), 0),
    -- Rejection rate % (rejected / (approved + rejected))
    'rejection_rate',       CASE
                              WHEN COUNT(*) FILTER (WHERE er.status IN ('approved','rejected')) = 0 THEN 0
                              ELSE ROUND(
                                (COUNT(*) FILTER (WHERE er.status = 'rejected'))::numeric * 100.0
                                / (COUNT(*) FILTER (WHERE er.status IN ('approved','rejected'))), 1)
                            END,
    -- Average approval time in hours (submitted_at → completed_at on workflow instance)
    'avg_approval_hours',   ROUND((AVG(
                              EXTRACT(EPOCH FROM (wi.completed_at - er.submitted_at)) / 3600.0
                            ) FILTER (WHERE er.status = 'approved' AND wi.completed_at IS NOT NULL))::numeric, 1),
    -- SLA compliance: % of approved reports completed within their template SLA
    -- (simplified: instances completed before any breach event was fired)
    'sla_compliance_rate',  CASE
                              WHEN COUNT(*) FILTER (WHERE er.status = 'approved') = 0 THEN NULL
                              ELSE ROUND(
                                (COUNT(*) FILTER (
                                  WHERE er.status = 'approved'
                                    AND NOT EXISTS (
                                      SELECT 1 FROM workflow_sla_events wse
                                      WHERE wse.instance_id = wi.id
                                        AND wse.event_type = 'breach'
                                    )
                                ))::numeric * 100.0
                                / NULLIF(COUNT(*) FILTER (WHERE er.status = 'approved'), 0), 1)
                            END
  ) INTO v_result
  FROM expense_reports er
  LEFT JOIN employees e ON e.id = er.employee_id
  LEFT JOIN (
    SELECT report_id, SUM(COALESCE(converted_amount, amount)) AS total
    FROM   expense_line_items
    GROUP  BY report_id
  ) li_totals ON li_totals.report_id = er.id
  LEFT JOIN workflow_instances wi
    ON  wi.module_code = 'expense_reports'
    AND wi.record_id   = er.id
    AND wi.id = (
      SELECT id FROM workflow_instances
      WHERE  module_code = 'expense_reports'
        AND  record_id   = er.id
      ORDER  BY created_at DESC
      LIMIT  1
    )
  WHERE er.deleted_at IS NULL
    AND er.submitted_at IS NOT NULL
    AND (p_date_from   IS NULL OR er.submitted_at >= p_date_from)
    AND (p_date_to     IS NULL OR er.submitted_at <  p_date_to)
    AND (p_dept_id     IS NULL OR e.dept_id        = p_dept_id)
    AND (p_employee_id IS NULL OR er.employee_id   = p_employee_id);

  RETURN COALESCE(v_result, '{}'::jsonb);
END;
$$;

COMMENT ON FUNCTION rpc_expense_kpis IS
  'Returns headline KPI numbers for the Expense Analytics dashboard. '
  'Filters: date range (submitted_at), department, employee.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. rpc_spend_by_department
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION rpc_spend_by_department(
  p_date_from   timestamptz DEFAULT NULL,
  p_date_to     timestamptz DEFAULT NULL,
  p_dept_id     uuid        DEFAULT NULL,
  p_employee_id uuid        DEFAULT NULL
)
RETURNS TABLE (
  dept_id   uuid,
  dept_name text,
  spend     numeric,
  count     bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    d.id                                        AS dept_id,
    d.name                                      AS dept_name,
    COALESCE(SUM(li_totals.total), 0)::numeric  AS spend,
    COUNT(er.id)                                AS count
  FROM expense_reports er
  JOIN employees e ON e.id = er.employee_id
  JOIN departments d ON d.id = e.dept_id
  LEFT JOIN (
    SELECT report_id, SUM(COALESCE(converted_amount, amount)) AS total
    FROM   expense_line_items
    GROUP  BY report_id
  ) li_totals ON li_totals.report_id = er.id
  WHERE er.deleted_at    IS NULL
    AND er.status         = 'approved'
    AND er.submitted_at  IS NOT NULL
    AND (p_date_from   IS NULL OR er.submitted_at >= p_date_from)
    AND (p_date_to     IS NULL OR er.submitted_at <  p_date_to)
    AND (p_dept_id     IS NULL OR e.dept_id        = p_dept_id)
    AND (p_employee_id IS NULL OR er.employee_id   = p_employee_id)
  GROUP BY d.id, d.name
  ORDER BY spend DESC;
END;
$$;

COMMENT ON FUNCTION rpc_spend_by_department IS
  'Returns approved spend grouped by department for the bar chart.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. rpc_expense_status_funnel
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION rpc_expense_status_funnel(
  p_date_from   timestamptz DEFAULT NULL,
  p_date_to     timestamptz DEFAULT NULL,
  p_dept_id     uuid        DEFAULT NULL,
  p_employee_id uuid        DEFAULT NULL
)
RETURNS TABLE (
  status text,
  count  bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    er.status::text,
    COUNT(*)        AS count
  FROM expense_reports er
  JOIN employees e ON e.id = er.employee_id
  WHERE er.deleted_at IS NULL
    AND (p_date_from   IS NULL OR er.submitted_at >= p_date_from OR er.status = 'draft')
    AND (p_date_to     IS NULL OR er.submitted_at <  p_date_to   OR er.status = 'draft')
    AND (p_dept_id     IS NULL OR e.dept_id        = p_dept_id)
    AND (p_employee_id IS NULL OR er.employee_id   = p_employee_id)
  GROUP BY er.status
  ORDER BY
    CASE er.status::text
      WHEN 'draft'            THEN 1
      WHEN 'submitted'        THEN 2
      WHEN 'manager_approved' THEN 3
      WHEN 'approved'         THEN 4
      WHEN 'rejected'         THEN 5
      ELSE 6
    END;
END;
$$;

COMMENT ON FUNCTION rpc_expense_status_funnel IS
  'Returns report count per status for the funnel/donut chart.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. rpc_monthly_spend_trend
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION rpc_monthly_spend_trend(
  p_months      integer     DEFAULT 6,
  p_dept_id     uuid        DEFAULT NULL,
  p_employee_id uuid        DEFAULT NULL
)
RETURNS TABLE (
  month       text,
  month_start date,
  spend       numeric,
  count       bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    TO_CHAR(DATE_TRUNC('month', er.submitted_at), 'Mon YYYY')  AS month,
    DATE_TRUNC('month', er.submitted_at)::date                 AS month_start,
    COALESCE(SUM(li_totals.total), 0)::numeric                 AS spend,
    COUNT(er.id)                                               AS count
  FROM expense_reports er
  JOIN employees e ON e.id = er.employee_id
  LEFT JOIN (
    SELECT report_id, SUM(COALESCE(converted_amount, amount)) AS total
    FROM   expense_line_items
    GROUP  BY report_id
  ) li_totals ON li_totals.report_id = er.id
  WHERE er.deleted_at  IS NULL
    AND er.status       = 'approved'
    AND er.submitted_at >= DATE_TRUNC('month', now()) - ((p_months - 1) || ' months')::interval
    AND (p_dept_id     IS NULL OR e.dept_id      = p_dept_id)
    AND (p_employee_id IS NULL OR er.employee_id = p_employee_id)
  GROUP BY DATE_TRUNC('month', er.submitted_at)
  ORDER BY month_start;
END;
$$;

COMMENT ON FUNCTION rpc_monthly_spend_trend IS
  'Returns approved spend per calendar month for the trend line chart.';


-- ════════════════════════════════════════════════════════════════════════════
-- 5. rpc_pending_approvals
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION rpc_pending_approvals(
  p_dept_id     uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
)
RETURNS TABLE (
  report_id       uuid,
  report_name     text,
  employee_name   text,
  dept_name       text,
  status          text,
  submitted_at    timestamptz,
  days_waiting    integer,
  total_amount    numeric,
  currency_code   text,
  current_step    text,
  assignee_name   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    er.id                                                                AS report_id,
    er.name                                                              AS report_name,
    e.name                                                               AS employee_name,
    d.name                                                               AS dept_name,
    er.status::text                                                      AS status,
    er.submitted_at                                                      AS submitted_at,
    EXTRACT(DAY FROM now() - er.submitted_at)::integer                  AS days_waiting,
    COALESCE(li_totals.total, 0)::numeric                               AS total_amount,
    er.base_currency_code                                                AS currency_code,
    ws.name                                                              AS current_step,
    assignee_emp.name                                                    AS assignee_name
  FROM expense_reports er
  JOIN employees e  ON e.id  = er.employee_id
  LEFT JOIN departments d ON d.id = e.dept_id
  LEFT JOIN (
    SELECT report_id, SUM(COALESCE(converted_amount, amount)) AS total
    FROM   expense_line_items
    GROUP  BY report_id
  ) li_totals ON li_totals.report_id = er.id
  -- Get most recent workflow instance
  LEFT JOIN LATERAL (
    SELECT * FROM workflow_instances wi
    WHERE  wi.module_code = 'expense_reports'
      AND  wi.record_id   = er.id
      AND  wi.status      = 'in_progress'
    ORDER  BY wi.created_at DESC
    LIMIT  1
  ) wi ON true
  -- Current pending task
  LEFT JOIN LATERAL (
    SELECT wt.*, ws2.name AS step_name_inner
    FROM   workflow_tasks wt
    LEFT JOIN workflow_steps ws2 ON ws2.id = wt.step_id
    WHERE  wt.instance_id = wi.id
      AND  wt.status      = 'pending'
    ORDER  BY wt.step_order
    LIMIT  1
  ) wt ON true
  LEFT JOIN workflow_steps ws ON ws.id = wt.step_id
  LEFT JOIN profiles assignee_p ON assignee_p.id = wt.assigned_to
  LEFT JOIN employees assignee_emp ON assignee_emp.id = assignee_p.employee_id
  WHERE er.deleted_at IS NULL
    AND er.status IN ('submitted', 'manager_approved')
    AND er.submitted_at IS NOT NULL
    AND (p_dept_id     IS NULL OR e.dept_id      = p_dept_id)
    AND (p_employee_id IS NULL OR er.employee_id = p_employee_id)
  ORDER BY er.submitted_at ASC;  -- oldest first = most urgent
END;
$$;

COMMENT ON FUNCTION rpc_pending_approvals IS
  'Returns in-flight expense reports sorted oldest-first for the pending approvals table.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, pronargs
FROM   pg_proc
WHERE  proname IN (
  'rpc_expense_kpis',
  'rpc_spend_by_department',
  'rpc_expense_status_funnel',
  'rpc_monthly_spend_trend',
  'rpc_pending_approvals'
)
ORDER BY proname;
