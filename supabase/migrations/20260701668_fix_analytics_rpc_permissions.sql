-- =============================================================================
-- Fix analytics RPC permission checks
--
-- Bug: wf_analytics_turnaround, wf_analytics_rejection_rates, and
--      wf_analytics_submitter_activity only accepted has_permission('workflow.admin').
--      Admins (has_role('admin')) were denied even though they should have full access.
--
-- Fix: align with get_approver_performance — accept has_role('admin') OR has_permission('workflow.admin').
-- =============================================================================

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
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
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
    ROUND(AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1)                          AS avg_hours_all,
    ROUND(AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.status = 'approved' AND wi.completed_at IS NOT NULL), 1) AS avg_hours_approved,
    ROUND(AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.status = 'rejected' AND wi.completed_at IS NOT NULL), 1) AS avg_hours_rejected,
    ROUND(MIN(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1)                          AS min_hours,
    ROUND(MAX(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1)                          AS max_hours
  FROM  workflow_instances wi
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  WHERE wi.created_at >= p_from::timestamptz
    AND wi.created_at <  (p_to + 1)::timestamptz
  GROUP BY tpl.id, tpl.name, tpl.code
  ORDER BY total_submitted DESC;
END;
$$;


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
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
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
    COUNT(*) FILTER (WHERE wt.status = 'pending' AND wt.due_at IS NOT NULL
                       AND wt.due_at < now())                                            AS overdue_now,
    COUNT(*) FILTER (WHERE wt.acted_at IS NOT NULL AND wt.due_at IS NOT NULL
                       AND wt.acted_at > wt.due_at)                                     AS completed_late,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wt.status = 'rejected')
      / NULLIF(COUNT(*) FILTER (WHERE wt.status IN ('approved','rejected')), 0), 1)      AS rejection_pct,
    ROUND(100.0 * (
        COUNT(*) FILTER (WHERE wt.acted_at IS NOT NULL AND wt.due_at IS NOT NULL AND wt.acted_at > wt.due_at)
      + COUNT(*) FILTER (WHERE wt.status = 'pending' AND wt.due_at IS NOT NULL AND wt.due_at < now())
    ) / NULLIF(COUNT(*) FILTER (WHERE wt.due_at IS NOT NULL), 0), 1)                    AS sla_breach_pct
  FROM  workflow_tasks     wt
  JOIN  workflow_instances wi  ON wi.id  = wt.instance_id
  JOIN  workflow_templates tpl ON tpl.id = wi.template_id
  JOIN  workflow_steps     ws  ON ws.id  = wt.step_id
  WHERE wi.created_at >= p_from::timestamptz
    AND wi.created_at <  (p_to + 1)::timestamptz
    AND wt.status NOT IN ('skipped', 'cancelled')
    AND ws.is_cc = false
  GROUP BY tpl.name, tpl.code, ws.step_order, ws.name, ws.sla_hours
  ORDER BY tpl.name, ws.step_order;
END;
$$;


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
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
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
    ROUND(AVG(EXTRACT(EPOCH FROM (wi.completed_at - wi.created_at)) / 3600.0)
      FILTER (WHERE wi.completed_at IS NOT NULL), 1)                              AS avg_turnaround_hours
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


SELECT proname FROM pg_proc
WHERE  proname IN ('wf_analytics_turnaround','wf_analytics_rejection_rates','wf_analytics_submitter_activity')
ORDER BY proname;
