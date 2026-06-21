-- =============================================================================
-- Migration 508: vw_wf_pending_tasks + vw_wf_my_requests — initiated_by_actor
--
-- Adds two columns to both views so the frontend can render
-- "Submitted by [actor] on behalf of [subject]" when HR submits for another employee.
--
--   initiated_by_actor_id    uuid   — profiles.id of the HR actor (NULL for self-service)
--   initiated_by_actor_name  text   — employees.name of that actor
--
-- Backward-compatible: both columns are NULL for all existing self-service rows.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. vw_wf_pending_tasks — approver inbox view
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS vw_wf_pending_tasks;

CREATE VIEW vw_wf_pending_tasks AS
SELECT
  wt.id                                        AS task_id,
  wi.id                                        AS instance_id,
  wt.assigned_to,
  ws.name                                      AS step_name,
  ws.allow_edit                                AS step_allow_edit,
  wt.step_order,
  tpl.code                                     AS template_code,
  tpl.name                                     AS template_name,
  wi.module_code,
  wi.record_id,
  COALESCE(wpc.proposed_data, wi.metadata)     AS metadata,
  wpc.current_data,
  wi.submitted_by,
  e_sub.name                                   AS submitted_by_name,
  e_sub.business_email                         AS submitted_by_email,
  wt.due_at,
  wt.created_at                                AS task_created_at,
  -- ── on-behalf-of (mig 508) ──────────────────────────────────────────────
  wi.initiated_by_actor_id,
  e_actor.name                                 AS initiated_by_actor_name,
  -- ────────────────────────────────────────────────────────────────────────
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now()                        THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours'  THEN 'due_soon'
    ELSE 'on_track'
  END                                          AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi    ON wi.id         = wt.instance_id
JOIN       workflow_steps      ws    ON ws.id         = wt.step_id
JOIN       workflow_templates  tpl   ON tpl.id        = wi.template_id
JOIN       profiles            sub   ON sub.id        = wi.submitted_by
LEFT JOIN  employees           e_sub ON e_sub.id      = sub.employee_id
LEFT JOIN  workflow_pending_changes wpc ON wpc.id     = wi.record_id
-- Actor who submitted on behalf of subject (NULL for self-service)
LEFT JOIN  profiles            p_actor  ON p_actor.id  = wi.initiated_by_actor_id
LEFT JOIN  employees           e_actor  ON e_actor.id  = p_actor.employee_id
WHERE      wt.status    = 'pending'
  AND      wi.status    = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Pending approval tasks for the current user. '
  'Mig 508: added initiated_by_actor_id + initiated_by_actor_name for on-behalf-of display.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. vw_wf_my_requests — subject employee's own workflow view
--    Also shows instances where submitted_by = auth.uid() OR the subject
--    is the current user's employee (i.e. HR submitted on their behalf).
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  COALESCE(wpc.proposed_data, wi.metadata)  AS metadata,
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  current_task.assigned_to   AS current_approver_id,
  e_apr.name                 AS current_approver_name,
  current_task.due_at        AS current_task_due,
  clarif.notes               AS clarification_message,
  e_clarif.name              AS clarification_from,
  clarif.created_at          AS clarification_at,
  -- ── on-behalf-of (mig 508) ──────────────────────────────────────────────
  wi.initiated_by_actor_id,
  e_actor.name               AS initiated_by_actor_name
  -- ────────────────────────────────────────────────────────────────────────
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
LEFT JOIN  workflow_pending_changes wpc ON wpc.id = wi.record_id
LEFT JOIN  workflow_tasks      current_task
             ON  current_task.instance_id = wi.id
             AND current_task.step_order  = wi.current_step
             AND current_task.status      = 'pending'
LEFT JOIN  profiles            p_apr ON p_apr.id        = current_task.assigned_to
LEFT JOIN  employees           e_apr ON e_apr.id        = p_apr.employee_id
LEFT JOIN LATERAL (
  SELECT wal.notes, wal.actor_id, wal.created_at
  FROM   workflow_action_log wal
  WHERE  wal.instance_id = wi.id
    AND  wal.action      IN ('returned_to_initiator', 'rejected')
  ORDER  BY wal.created_at DESC
  LIMIT  1
) clarif ON true
LEFT JOIN  profiles            p_clarif ON p_clarif.id   = clarif.actor_id
LEFT JOIN  employees           e_clarif ON e_clarif.id   = p_clarif.employee_id
-- Actor who submitted on behalf of subject
LEFT JOIN  profiles            p_actor  ON p_actor.id    = wi.initiated_by_actor_id
LEFT JOIN  employees           e_actor  ON e_actor.id    = p_actor.employee_id
-- Show: (a) rows submitted by me, OR (b) rows where I am the subject employee
-- (b) covers the case where HR submitted on my behalf
WHERE (
  wi.submitted_by = auth.uid()
  OR EXISTS (
    SELECT 1 FROM profiles me
    WHERE  me.id          = auth.uid()
      AND  wpc.record_id  = me.employee_id  -- wpc.record_id = target employee UUID for profile modules
  )
)
ORDER BY   wi.updated_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'Workflow instances for the current user — both self-submitted and submitted on their behalf. '
  'Mig 508: added initiated_by_actor_id + initiated_by_actor_name; expanded WHERE to include '
  'instances where the user is the subject employee (HR submitted on their behalf).';

-- =============================================================================
-- END OF MIGRATION 508
-- =============================================================================
