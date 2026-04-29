-- =============================================================================
-- Migration 053: Workflow Analytics RPCs
--
-- Three read-only SECURITY DEFINER functions for the Reports & Analytics screen.
-- All require workflow.admin permission.
--
-- Functions:
--   wf_analytics_turnaround(p_from, p_to)        — avg completion time by template
--   wf_analytics_rejection_rates(p_from, p_to)   — rejection & SLA breach rates by step
--   wf_analytics_submitter_activity(p_from, p_to) — submissions per employee
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. wf_analytics_turnaround
--    Returns one row per workflow template with completion counts and average
--    turnaround time (hours) for approved and rejected instances.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_analytics_turnaround(
  p_from date DEFAULT (now() - interval '30 days')::date,
  p_to   date DEFAULT now()::date
)
RETURNS TABLE (
  template_id          uuid,
  template_name        text,
  template_code        text,
  total_submitted      bigint,
  approved_count       bigint,
  rejected_count       bigint,
  in_progress_count    bigint,
  avg_hours_all        numeric,
  avg_hours_approved   numeric,
  avg_hours_rejected   numeric,
  min_hours            numeric,
  max_hours            numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_analytics_turnaround: permission denied';
  END IF;

  RETURN QUERY
  SELECT
    tpl.id                                                                     AS template_id,
    tpl.name                                                                   AS template_name,
    tpl.code                                                                   AS template_code,
    COUNT(*)                                                                   AS total_submitted,
    COUNT(*) FILTER (WHERE wi.status = 'approved')                            AS approved_count,
    COUNT(*) FILTER (WHERE wi.status = 'rejected')                            AS rejected_count,
    COUNT(*) FILTER (WHERE wi.status IN ('in_progress','awaiting_clarification')) AS in_progress_count,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1
    )                                                                          AS avg_hours_all,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.status = 'approved' AND wi.completed_at IS NOT NULL), 1
    )                                                                          AS avg_hours_approved,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.status = 'rejected' AND wi.completed_at IS NOT NULL), 1
    )                                                                          AS avg_hours_rejected,
    ROUND(
      MIN(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1
    )                                                                          AS min_hours,
    ROUND(
      MAX(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1
    )                                                                          AS max_hours
  FROM  workflow_instances wi
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  WHERE wi.created_at >= p_from::timestamptz
    AND wi.created_at <  (p_to + 1)::timestamptz
  GROUP BY tpl.id, tpl.name, tpl.code
  ORDER BY total_submitted DESC;
END;
$$;

COMMENT ON FUNCTION wf_analytics_turnaround(date, date) IS
  'Returns approval turnaround KPIs per workflow template for the given date range. '
  'Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_analytics_rejection_rates
--    Returns one row per template+step combination with task counts,
--    rejection percentage, and SLA breach percentage.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_analytics_rejection_rates(
  p_from date DEFAULT (now() - interval '30 days')::date,
  p_to   date DEFAULT now()::date
)
RETURNS TABLE (
  template_name    text,
  template_code    text,
  step_order       integer,
  step_name        text,
  sla_hours        integer,
  total_tasks      bigint,
  approved_count   bigint,
  rejected_count   bigint,
  overdue_now      bigint,
  completed_late   bigint,
  rejection_pct    numeric,
  sla_breach_pct   numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_analytics_rejection_rates: permission denied';
  END IF;

  RETURN QUERY
  SELECT
    tpl.name                                                                              AS template_name,
    tpl.code                                                                              AS template_code,
    ws.step_order,
    ws.name                                                                               AS step_name,
    ws.sla_hours,
    COUNT(*)                                                                              AS total_tasks,
    COUNT(*) FILTER (WHERE wt.status = 'approved')                                       AS approved_count,
    COUNT(*) FILTER (WHERE wt.status = 'rejected')                                       AS rejected_count,
    -- tasks still pending and past due_at right now
    COUNT(*) FILTER (WHERE wt.status = 'pending' AND wt.due_at IS NOT NULL
                       AND wt.due_at < now())                                            AS overdue_now,
    -- tasks completed but took longer than sla
    COUNT(*) FILTER (WHERE wt.acted_at IS NOT NULL AND wt.due_at IS NOT NULL
                       AND wt.acted_at > wt.due_at)                                     AS completed_late,
    ROUND(
      100.0 * COUNT(*) FILTER (WHERE wt.status = 'rejected')
      / NULLIF(COUNT(*) FILTER (WHERE wt.status IN ('approved','rejected')), 0),
      1
    )                                                                                     AS rejection_pct,
    ROUND(
      100.0 * (
        COUNT(*) FILTER (WHERE wt.acted_at IS NOT NULL AND wt.due_at IS NOT NULL
                           AND wt.acted_at > wt.due_at)
        + COUNT(*) FILTER (WHERE wt.status = 'pending' AND wt.due_at IS NOT NULL
                             AND wt.due_at < now())
      ) / NULLIF(COUNT(*) FILTER (WHERE wt.due_at IS NOT NULL), 0),
      1
    )                                                                                     AS sla_breach_pct
  FROM  workflow_tasks     wt
  JOIN  workflow_instances wi  ON wi.id  = wt.instance_id
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  JOIN  workflow_steps     ws  ON ws.id  = wt.step_id
  WHERE wi.created_at >= p_from::timestamptz
    AND wi.created_at <  (p_to + 1)::timestamptz
    AND wt.status NOT IN ('skipped', 'cancelled')
  GROUP BY tpl.name, tpl.code, ws.step_order, ws.name, ws.sla_hours
  ORDER BY tpl.name, ws.step_order;
END;
$$;

COMMENT ON FUNCTION wf_analytics_rejection_rates(date, date) IS
  'Returns rejection and SLA breach rates per workflow template step for the '
  'given date range. Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_analytics_submitter_activity
--    Returns one row per employee who submitted at least one workflow instance
--    in the date range. Sorted by total submissions descending.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_analytics_submitter_activity(
  p_from date DEFAULT (now() - interval '30 days')::date,
  p_to   date DEFAULT now()::date
)
RETURNS TABLE (
  employee_id            uuid,
  employee_name          text,
  department_name        text,
  total_submissions      bigint,
  approved_count         bigint,
  rejected_count         bigint,
  in_progress_count      bigint,
  avg_turnaround_hours   numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT has_permission('workflow.admin') THEN
    RAISE EXCEPTION 'wf_analytics_submitter_activity: permission denied';
  END IF;

  RETURN QUERY
  SELECT
    emp.id                                                                         AS employee_id,
    emp.name                                                                       AS employee_name,
    dept.name                                                                      AS department_name,
    COUNT(*)                                                                       AS total_submissions,
    COUNT(*) FILTER (WHERE wi.status = 'approved')                                AS approved_count,
    COUNT(*) FILTER (WHERE wi.status = 'rejected')                                AS rejected_count,
    COUNT(*) FILTER (WHERE wi.status IN ('in_progress','awaiting_clarification')) AS in_progress_count,
    ROUND(
      AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1
    )                                                                              AS avg_turnaround_hours
  FROM  workflow_instances wi
  JOIN  profiles           p    ON p.id    = wi.submitted_by
  JOIN  employees          emp  ON emp.id  = p.employee_id
  LEFT JOIN departments    dept ON dept.id = emp.dept_id
  WHERE wi.created_at >= p_from::timestamptz
    AND wi.created_at <  (p_to + 1)::timestamptz
  GROUP BY emp.id, emp.name, dept.name
  ORDER BY total_submissions DESC
  LIMIT 100;
END;
$$;

COMMENT ON FUNCTION wf_analytics_submitter_activity(date, date) IS
  'Returns per-employee submission activity and turnaround stats for the given '
  'date range. Capped at 100 rows. Requires workflow.admin permission.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, pronargs
FROM   pg_proc
WHERE  proname IN (
  'wf_analytics_turnaround',
  'wf_analytics_rejection_rates',
  'wf_analytics_submitter_activity'
)
ORDER BY proname;
