-- =============================================================================
-- Migration 591: vw_wf_operations — show subject employee name, not submitter
--
-- Bug: the "Employee" column in Workflow Operations showed the submitter's name
-- (e.g. "Vijay Aananth SR" for an HR-initiated termination) instead of the
-- subject employee being acted on (e.g. "Abdul Malik").
--
-- Fix: resolve employee name from subject_profile_id when set (on-behalf
-- submissions), falling back to submitted_by for self-service submissions.
-- Department also corrected to follow the subject employee, not the submitter.
-- =============================================================================

DROP VIEW IF EXISTS vw_wf_operations;

CREATE VIEW vw_wf_operations AS
SELECT
  -- Identity
  wt.id                                                               AS task_id,
  wi.id                                                               AS instance_id,

  -- Human-readable display ID
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

  -- Submitter (who clicked Submit — kept for audit/return-to-submitter flows)
  wi.submitted_by                                                     AS submitter_id,
  submitter_emp.name                                                  AS submitter_name,

  -- Subject employee (who the workflow is ABOUT — Abdul Malik for termination,
  -- same as submitter for self-service). Used for the "Employee" column.
  COALESCE(subject_emp.name,  submitter_emp.name)                    AS subject_name,
  COALESCE(subject_emp.dept_id, submitter_emp.dept_id)               AS subject_dept_id,

  -- Department (follows subject employee, not submitter)
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

-- Subject employee: populated for on-behalf submissions (mig 528).
-- NULL for self-service → COALESCE falls back to submitter columns above.
LEFT JOIN  profiles            subject_p    ON subject_p.id  = wi.subject_profile_id
                                           AND wi.subject_profile_id IS DISTINCT FROM wi.submitted_by
LEFT JOIN  employees           subject_emp  ON subject_emp.id = subject_p.employee_id

-- Department follows the subject employee when available, else submitter
LEFT JOIN  departments         dept         ON dept.id = COALESCE(subject_emp.dept_id, submitter_emp.dept_id)

WHERE wt.status = 'pending'
  AND wi.status IN ('in_progress', 'awaiting_clarification');

COMMENT ON VIEW vw_wf_operations IS
  'Mig 591: Employee column now shows subject_name (subject employee for on-behalf '
  'submissions, submitter for self-service). submitter_name retained for audit/return flows. '
  'Department also follows the subject employee.';
