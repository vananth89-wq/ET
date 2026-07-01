-- =============================================================================
-- Fix approver performance RPCs — date window filtering
--
-- Bug: all three RPCs filtered by wt.created_at / wi.created_at only.
-- This meant that tasks approved/rejected from older workflows were invisible,
-- causing avg_hours / avg_step_hours to return NaN or NULL even when approvers
-- were actively working.
--
-- Fix: each RPC now uses the most semantically correct timestamp per use-case:
--
--   get_workflow_summary
--     - instances: still filtered by wi.created_at (instance submission date)
--     - step_times: now filtered by wt.acted_at (when the action occurred)
--
--   get_approver_performance
--     - actioned CTE: now filtered by wt.acted_at (when they acted)
--     - pending_now: unchanged — always a live snapshot
--
--   get_step_bottlenecks
--     - total_tasks: tasks touched in period = created OR acted-on within window
--     - avg_hours / median_hours: only tasks acted on within the window
--     - overdue_count: unchanged (live pending tasks past due_at)
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. get_workflow_summary  (step_times now uses acted_at window)
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
    SELECT wi.id, wi.status, wi.created_at, wi.completed_at
    FROM   workflow_instances wi
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wi.created_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  ),
  step_times AS (
    -- Use acted_at for the window so we capture all actions in the period,
    -- even for workflow instances created before p_from.
    SELECT EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600 AS hours
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi  ON wi.id  = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.acted_at IS NOT NULL
      AND  wt.acted_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  )
  SELECT
    COUNT(*)                                                          AS submitted_count,
    COUNT(*) FILTER (WHERE status = 'approved')                       AS completed_count,
    COUNT(*) FILTER (WHERE status = 'rejected')                       AS rejected_count,
    COUNT(*) FILTER (WHERE status = 'withdrawn')                      AS withdrawn_count,
    COUNT(*) FILTER (WHERE status IN ('in_progress','awaiting_clarification'))
                                                                      AS in_progress_count,
    ROUND(
      AVG(
        EXTRACT(EPOCH FROM (completed_at - created_at)) / 3600
      ) FILTER (WHERE completed_at IS NOT NULL),
      1
    )                                                                 AS avg_completion_hours,
    ROUND((SELECT AVG(hours) FROM step_times), 1)                     AS avg_step_hours
  FROM instances;
END;
$$;

COMMENT ON FUNCTION get_workflow_summary(timestamptz, timestamptz, text) IS
  'Overall workflow KPIs for a given period. '
  'Instance counts filtered by wi.created_at; avg_step_hours filtered by wt.acted_at '
  'so approvals on older instances are included.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. get_approver_performance  (actioned CTE now uses acted_at window)
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
    -- Tasks acted on within the period.
    -- Filter by acted_at so we capture all approver work in the window,
    -- regardless of when the instance/task was originally created.
    SELECT
      wt.assigned_to,
      wt.status,
      EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600 AS hours_to_act
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi  ON wi.id  = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.acted_at IS NOT NULL
      AND  wt.acted_at BETWEEN p_from AND p_to
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
  ),
  pending_now AS (
    -- Live snapshot of pending tasks right now (no date filter intentional).
    SELECT wt.assigned_to,
           COUNT(*)                                         AS pending_count,
           COUNT(*) FILTER (WHERE wt.due_at < now())       AS overdue_count
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi  ON wi.id  = wt.instance_id
    JOIN   workflow_templates tpl ON tpl.id = wi.template_id
    WHERE  wt.status = 'pending'
      AND  wi.status = 'in_progress'
      AND  (p_template_code IS NULL OR tpl.code = p_template_code)
    GROUP  BY wt.assigned_to
  )
  SELECT
    p.id                                                            AS approver_id,
    e.name                                                          AS approver_name,
    d.name                                                          AS department_name,
    e.job_title,
    COUNT(a.status) FILTER (WHERE a.status IN ('approved','rejected','returned','reassigned'))
                                                                    AS total_actioned,
    COUNT(a.status) FILTER (WHERE a.status = 'approved')            AS approved_count,
    COUNT(a.status) FILTER (WHERE a.status = 'rejected')            AS rejected_count,
    COUNT(a.status) FILTER (WHERE a.status IN ('returned','returned_to_initiator'))
                                                                    AS returned_count,
    COUNT(a.status) FILTER (WHERE a.status = 'reassigned')          AS reassigned_count,
    COALESCE(pn.pending_count, 0)                                   AS pending_count,
    COALESCE(pn.overdue_count, 0)                                   AS overdue_count,
    ROUND(AVG(a.hours_to_act), 1)                                   AS avg_hours,
    ROUND(CAST(
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY a.hours_to_act)
    AS numeric), 1)                                                 AS median_hours,
    ROUND(
      100.0 * COUNT(a.status) FILTER (WHERE a.status = 'approved')
        / NULLIF(COUNT(a.status) FILTER (WHERE a.status IN ('approved','rejected')), 0),
      1
    )                                                               AS approval_rate
  FROM       profiles     p
  JOIN       employees    e  ON e.id = p.employee_id
  LEFT JOIN  departments  d  ON d.id = e.dept_id
  LEFT JOIN  actioned     a  ON a.assigned_to = p.id
  LEFT JOIN  pending_now  pn ON pn.assigned_to = p.id
  WHERE p.is_active = true
    AND (
      a.assigned_to IS NOT NULL
      OR pn.assigned_to IS NOT NULL
    )
  GROUP BY p.id, e.name, d.name, e.job_title, pn.pending_count, pn.overdue_count
  ORDER BY avg_hours DESC NULLS LAST;
END;
$$;

COMMENT ON FUNCTION get_approver_performance(timestamptz, timestamptz, text) IS
  'Per-approver performance stats for the given period. '
  'Filtered by wt.acted_at so all approvals in the window are counted, '
  'even for instances created before the window. '
  'Restricted to admin / workflow.admin.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. get_step_bottlenecks  (total_tasks = created OR acted in period;
--                           avg/median = only tasks acted in period)
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
    tpl.code                                                        AS template_code,
    tpl.name                                                        AS template_name,
    ws.step_order,
    ws.name                                                         AS step_name,

    -- total_tasks: all tasks that touched the period (created or acted on)
    COUNT(wt.id)                                                    AS total_tasks,

    -- avg_hours: only over tasks actually completed in the period
    ROUND(AVG(
      EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600
    ) FILTER (WHERE wt.acted_at BETWEEN p_from AND p_to), 1)        AS avg_hours,

    -- median_hours: same — only completed tasks in the period
    ROUND(CAST(
      PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (wt.acted_at - wt.created_at)) / 3600
      ) FILTER (WHERE wt.acted_at BETWEEN p_from AND p_to)
    AS numeric), 1)                                                 AS median_hours,

    -- overdue: live count of pending tasks past their SLA
    COUNT(wt.id) FILTER (
      WHERE wt.status = 'pending' AND wt.due_at < now()
    )                                                               AS overdue_count,

    ws.sla_hours

  FROM       workflow_tasks      wt
  JOIN       workflow_steps      ws  ON ws.id  = wt.step_id
  JOIN       workflow_instances  wi  ON wi.id  = wt.instance_id
  JOIN       workflow_templates  tpl ON tpl.id = wi.template_id

  -- Include tasks created in the period OR acted on in the period
  WHERE  (
    wt.created_at BETWEEN p_from AND p_to
    OR wt.acted_at BETWEEN p_from AND p_to
  )
    AND  (p_template_code IS NULL OR tpl.code = p_template_code)

  GROUP BY tpl.code, tpl.name, ws.step_order, ws.name, ws.sla_hours
  ORDER BY tpl.code, ws.step_order;
END;
$$;

COMMENT ON FUNCTION get_step_bottlenecks(timestamptz, timestamptz, text) IS
  'Per-step performance stats for the given period. '
  'total_tasks counts tasks created OR acted on in the window. '
  'avg_hours and median_hours are computed only over tasks acted on in the window, '
  'so recently-approved tasks on older instances are always included.';


-- ── Verify all three functions exist ─────────────────────────────────────────
SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'get_workflow_summary',
  'get_approver_performance',
  'get_step_bottlenecks'
)
ORDER BY proname;
