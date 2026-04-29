-- =============================================================================
-- Approver Performance Dashboard
--
-- Three RPCs powering the HR/admin performance dashboard:
--
--   get_workflow_summary(p_from, p_to, p_template_code)
--     Overall KPIs for the period: submitted, completed, rejected,
--     in_progress, avg completion hours, avg step hours.
--
--   get_approver_performance(p_from, p_to, p_template_code)
--     Per-approver stats: tasks actioned, approval rate, avg/median
--     hours to act, overdue count, current pending count.
--     Restricted to admin / workflow.admin.
--
--   get_step_bottlenecks(p_from, p_to, p_template_code)
--     Per-step aggregate: avg hours, median hours, total tasks,
--     overdue count. Used to render the bottleneck bar chart.
--
-- All three accept:
--   p_from           timestamptz  — period start (inclusive)
--   p_to             timestamptz  — period end   (inclusive)
--   p_template_code  text DEFAULT NULL — filter to one template; NULL = all
--
-- Security: SECURITY DEFINER so the aggregates work despite RLS.
--   get_approver_performance additionally checks has_role('admin') OR
--   has_permission('workflow.admin') and raises an exception if the caller
--   is neither.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. get_workflow_summary
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_workflow_summary(
  p_from          timestamptz,
  p_to            timestamptz,
  p_template_code text DEFAULT NULL
)
RETURNS TABLE (
  submitted_count        bigint,
  completed_count        bigint,
  rejected_count         bigint,
  withdrawn_count        bigint,
  in_progress_count      bigint,
  avg_completion_hours   numeric,
  avg_step_hours         numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH instances AS (
    SELECT wi.id, wi.status, wi.created_at, wi.completed_at, wi.template_id
    FROM   workflow_instances wi
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wi.created_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  ),
  step_times AS (
    SELECT EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600 AS hours
    FROM   workflow_tasks wt
    JOIN   workflow_instances wi ON wi.id = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.acted_at IS NOT NULL
      AND  wt.created_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  )
  SELECT
    COUNT(*)                                                        AS submitted_count,
    COUNT(*) FILTER (WHERE status = 'approved')                     AS completed_count,
    COUNT(*) FILTER (WHERE status = 'rejected')                     AS rejected_count,
    COUNT(*) FILTER (WHERE status = 'withdrawn')                    AS withdrawn_count,
    COUNT(*) FILTER (WHERE status IN ('in_progress','awaiting_clarification')) AS in_progress_count,
    ROUND(
      AVG(
        EXTRACT(EPOCH FROM (completed_at - created_at)) / 3600
      ) FILTER (WHERE completed_at IS NOT NULL),
      1
    )                                                               AS avg_completion_hours,
    ROUND((SELECT AVG(hours) FROM step_times), 1)                   AS avg_step_hours
  FROM instances;
END;
$$;

COMMENT ON FUNCTION get_workflow_summary(timestamptz, timestamptz, text) IS
  'Overall workflow KPIs for a given period. Callable by any authenticated user.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. get_approver_performance
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_approver_performance(
  p_from          timestamptz,
  p_to            timestamptz,
  p_template_code text DEFAULT NULL
)
RETURNS TABLE (
  approver_id       uuid,
  approver_name     text,
  department_name   text,
  job_title         text,
  total_actioned    bigint,
  approved_count    bigint,
  rejected_count    bigint,
  returned_count    bigint,
  reassigned_count  bigint,
  pending_count     bigint,
  overdue_count     bigint,
  avg_hours         numeric,
  median_hours      numeric,
  approval_rate     numeric    -- 0–100
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- ── Access check ───────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'get_approver_performance: insufficient permissions';
  END IF;

  RETURN QUERY
  WITH actioned AS (
    -- Tasks that were acted on within the period (assigned + acted)
    SELECT
      wt.assigned_to,
      wt.status,
      CASE
        WHEN wt.acted_at IS NOT NULL
        THEN EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600
      END AS hours_to_act
    FROM   workflow_tasks wt
    JOIN   workflow_instances wi  ON wi.id  = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.created_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  ),
  pending_now AS (
    -- Current pending tasks (regardless of period — snapshot of right now)
    SELECT wt.assigned_to,
           COUNT(*)                                          AS pending_count,
           COUNT(*) FILTER (WHERE wt.due_at < now())        AS overdue_count
    FROM   workflow_tasks wt
    JOIN   workflow_instances wi  ON wi.id  = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.status = 'pending'
      AND  wi.status = 'in_progress'
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
    GROUP  BY wt.assigned_to
  )
  SELECT
    p.id                                                          AS approver_id,
    e.name                                                        AS approver_name,
    d.name                                                        AS department_name,
    e.job_title,
    COUNT(a.status)   FILTER (WHERE a.status IN ('approved','rejected','returned','reassigned'))
                                                                  AS total_actioned,
    COUNT(a.status)   FILTER (WHERE a.status = 'approved')        AS approved_count,
    COUNT(a.status)   FILTER (WHERE a.status = 'rejected')        AS rejected_count,
    COUNT(a.status)   FILTER (WHERE a.status IN ('returned','returned_to_initiator'))
                                                                  AS returned_count,
    COUNT(a.status)   FILTER (WHERE a.status = 'reassigned')      AS reassigned_count,
    COALESCE(pn.pending_count, 0)                                 AS pending_count,
    COALESCE(pn.overdue_count, 0)                                 AS overdue_count,
    ROUND(AVG(a.hours_to_act)
      FILTER (WHERE a.hours_to_act IS NOT NULL), 1)               AS avg_hours,
    ROUND(CAST(
      PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY a.hours_to_act
      ) FILTER (WHERE a.hours_to_act IS NOT NULL)
    AS numeric), 1)                                               AS median_hours,
    ROUND(
      100.0 * COUNT(a.status) FILTER (WHERE a.status = 'approved')
        / NULLIF(COUNT(a.status) FILTER (WHERE a.status IN ('approved','rejected')), 0),
      1
    )                                                             AS approval_rate
  FROM       profiles     p
  JOIN       employees    e  ON e.id = p.employee_id
  LEFT JOIN  departments  d  ON d.id = e.dept_id
  LEFT JOIN  actioned     a  ON a.assigned_to = p.id
  LEFT JOIN  pending_now  pn ON pn.assigned_to = p.id
  WHERE p.is_active = true
    AND (
      -- Only include approvers who had tasks in the period OR have pending now
      a.assigned_to IS NOT NULL
      OR pn.assigned_to IS NOT NULL
    )
  GROUP BY p.id, e.name, d.name, e.job_title, pn.pending_count, pn.overdue_count
  ORDER BY avg_hours DESC NULLS LAST;
END;
$$;

COMMENT ON FUNCTION get_approver_performance(timestamptz, timestamptz, text) IS
  'Per-approver performance stats for the given period. '
  'Restricted to admin / workflow.admin. '
  'Returns avg/median hours to act, approval rate, overdue and pending counts.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. get_step_bottlenecks
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_step_bottlenecks(
  p_from          timestamptz,
  p_to            timestamptz,
  p_template_code text DEFAULT NULL
)
RETURNS TABLE (
  template_code    text,
  template_name    text,
  step_order       integer,
  step_name        text,
  total_tasks      bigint,
  avg_hours        numeric,
  median_hours     numeric,
  overdue_count    bigint,
  sla_hours        integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    tpl.code                                                      AS template_code,
    tpl.name                                                      AS template_name,
    ws.step_order,
    ws.name                                                       AS step_name,
    COUNT(wt.id)                                                  AS total_tasks,
    ROUND(AVG(
      EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600
    ) FILTER (WHERE wt.acted_at IS NOT NULL), 1)                  AS avg_hours,
    ROUND(CAST(
      PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600
      ) FILTER (WHERE wt.acted_at IS NOT NULL)
    AS numeric), 1)                                               AS median_hours,
    COUNT(wt.id) FILTER (
      WHERE wt.status = 'pending' AND wt.due_at < now()
    )                                                             AS overdue_count,
    ws.sla_hours
  FROM       workflow_tasks      wt
  JOIN       workflow_steps      ws  ON ws.id  = wt.step_id
  JOIN       workflow_instances  wi  ON wi.id  = wt.instance_id
  JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
  WHERE  wt.created_at BETWEEN p_from AND p_to
    AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  GROUP BY tpl.code, tpl.name, ws.step_order, ws.name, ws.sla_hours
  ORDER BY tpl.code, ws.step_order;
END;
$$;

COMMENT ON FUNCTION get_step_bottlenecks(timestamptz, timestamptz, text) IS
  'Per-step performance stats for the given period. '
  'Used to render the bottleneck bar chart. Callable by any authenticated user.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'get_workflow_summary',
  'get_approver_performance',
  'get_step_bottlenecks'
)
ORDER BY proname;
