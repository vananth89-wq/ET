-- =============================================================================
-- Workflow Operations — gap fixes
--
-- Fixes applied on top of migration 050:
--   1. Seed wf.task_assigned notification template (used by wf_force_advance)
--   2. Rebuild vw_wf_operations to expose tpl.id AS template_id so the
--      frontend no longer needs a second round-trip to workflow_instances
--      when loading remaining steps for the Force Advance panel.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. wf.task_assigned notification template
--
-- Referenced by wf_force_advance() when notifying the new approver.
-- Also used by any future code that assigns a fresh task to someone.
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES (
  'wf.task_assigned',
  'New approval task: {{step_name}}',
  'You have been assigned to approve a request at the "{{step_name}}" stage. Please review it in your Workflow Inbox.'
)
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Rebuild vw_wf_operations — add template_id column
--
-- Adds tpl.id AS template_id so the frontend can load remaining workflow
-- steps in a single query (no nested workflow_instances lookup required).
-- All other columns are unchanged from migration 050.
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_wf_operations;

CREATE VIEW vw_wf_operations AS
SELECT
  -- Identity
  wt.id                                                               AS task_id,
  wi.id                                                               AS instance_id,

  -- Human-readable display ID: prefix + YYYYMMDD + 6-char UUID fragment
  upper(
    CASE wi.module_code
      WHEN 'expense_reports'  THEN 'EXP'
      WHEN 'leave_requests'   THEN 'LVE'
      WHEN 'travel_requests'  THEN 'TRV'
      WHEN 'purchase_orders'  THEN 'PO'
      ELSE 'WF'
    END
    || '-' || to_char(wi.created_at, 'YYYYMMDD')
    || '-' || upper(left(wi.id::text, 6))
  )                                                                   AS display_id,

  -- Template / module
  tpl.id                                                              AS template_id,
  tpl.code                                                            AS template_code,
  tpl.name                                                            AS template_name,
  wi.module_code,
  wi.record_id,
  wi.status                                                           AS instance_status,

  -- Current step
  wt.step_order,
  ws.name                                                             AS step_name,
  ws.sla_hours,

  -- Assignee (current approver blocking the workflow)
  wt.assigned_to                                                      AS assignee_id,
  assignee_emp.name                                                   AS assignee_name,
  assignee_emp.job_title                                              AS assignee_job_title,

  -- Submitter
  wi.submitted_by                                                     AS submitter_id,
  submitter_emp.name                                                  AS submitter_name,

  -- Department (submitter's department)
  dept.id                                                             AS department_id,
  dept.name                                                           AS department_name,

  -- Timing
  wi.created_at                                                       AS submitted_at,
  wt.created_at                                                       AS pending_since,
  wt.due_at,

  -- Age of the current pending task
  ROUND(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 3600, 1
  )                                                                   AS age_hours,
  FLOOR(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 86400
  )::integer                                                          AS age_days,

  -- SLA classification
  CASE
    WHEN wt.due_at IS NULL OR wt.due_at > now()
      THEN 'normal'
    WHEN ws.sla_hours IS NOT NULL
     AND now() >= wt.due_at + (ws.sla_hours * interval '1 hour')
      THEN 'critical'
    ELSE 'overdue'
  END                                                                 AS sla_status

FROM       workflow_tasks      wt
JOIN       workflow_instances  wi           ON wi.id  = wt.instance_id
JOIN       workflow_steps      ws           ON ws.id  = wt.step_id
JOIN       workflow_templates  tpl          ON tpl.id = wi.template_id
JOIN       profiles            assignee_p   ON assignee_p.id = wt.assigned_to
JOIN       employees           assignee_emp ON assignee_emp.id = assignee_p.employee_id
JOIN       profiles            submitter_p  ON submitter_p.id = wi.submitted_by
JOIN       employees           submitter_emp ON submitter_emp.id = submitter_p.employee_id
LEFT JOIN  departments         dept         ON dept.id = submitter_emp.dept_id

WHERE wt.status = 'pending'
  AND wi.status IN ('in_progress', 'awaiting_clarification');

COMMENT ON VIEW vw_wf_operations IS
  'System-wide view of all active pending workflow tasks. '
  'Readable by admin / workflow.admin only (enforced via table RLS). '
  'Includes template_id (for step loading), computed age, and SLA status.';


-- ════════════════════════════════════════════════════════════════════════════
-- Verification
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm template_id column now present
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name   = 'vw_wf_operations'
  AND  column_name  = 'template_id';

-- Confirm wf.task_assigned template seeded
SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code = 'wf.task_assigned';
