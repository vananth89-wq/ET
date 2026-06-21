-- Migration 531: Fix vw_wf_my_requests duplicating rows for ROLE fan-out steps
--
-- Bug: ROLE-type steps fan out to N tasks (one per role member). The view joined
-- workflow_tasks on (instance_id, current_step, status='pending'), producing N rows
-- for the same instance — one per assignee. My Requests showed 5 identical cards
-- for a single submission when the current step had 5 pending tasks.
--
-- Fix:
--   • DISTINCT ON (wi.id) — one row per instance, deterministic by updated_at DESC.
--   • current_step_name — the step name from workflow_steps, shown instead of
--     an individual approver name when a ROLE step has multiple pending tasks.
--   • current_approver_name — kept for single-assignee steps (SPECIFIC_USER, MANAGER).
--     NULL when the step has multiple pending tasks (i.e. ROLE fan-out active).
--   • pending_task_count — number of pending tasks at the current step; UI can use
--     this to decide whether to show a name ("Awaiting: Vijey") or a step name
--     ("Awaiting: HR Analyst").

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT DISTINCT ON (wi.id)
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  COALESCE(wpc.proposed_data, wi.metadata)  AS metadata,
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  ws.name               AS current_step_name,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  -- Only expose a single approver name when there is exactly one pending task
  -- at the current step (i.e. not a ROLE fan-out). NULL otherwise — UI falls
  -- back to current_step_name.
  CASE WHEN pending.task_count = 1 THEN single_task.assigned_name ELSE NULL END
                        AS current_approver_name,
  single_task.due_at    AS current_task_due,
  pending.task_count    AS pending_task_count,
  clarif.notes               AS clarification_message,
  e_clarif.name              AS clarification_from,
  clarif.created_at          AS clarification_at,
  wi.initiated_by_actor_id,
  e_actor.name               AS initiated_by_actor_name
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
-- Step name for the current step
LEFT JOIN  workflow_steps      ws
             ON  ws.template_id = wi.template_id
             AND ws.step_order  = wi.current_step
             AND ws.is_active   = true
LEFT JOIN  workflow_pending_changes wpc ON wpc.id = wi.record_id
-- Count of pending tasks at the current step (determines ROLE fan-out)
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS task_count
  FROM   workflow_tasks wt
  WHERE  wt.instance_id = wi.id
    AND  wt.step_order  = wi.current_step
    AND  wt.status      = 'pending'
) pending ON true
-- Single-task assignee (only meaningful when task_count = 1)
LEFT JOIN LATERAL (
  SELECT wt.assigned_to, e.name AS assigned_name, wt.due_at
  FROM   workflow_tasks wt
  JOIN   profiles  p ON p.id  = wt.assigned_to
  JOIN   employees e ON e.id  = p.employee_id
  WHERE  wt.instance_id = wi.id
    AND  wt.step_order  = wi.current_step
    AND  wt.status      = 'pending'
  LIMIT  1
) single_task ON true
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
LEFT JOIN  profiles            p_actor  ON p_actor.id    = wi.initiated_by_actor_id
LEFT JOIN  employees           e_actor  ON e_actor.id    = p_actor.employee_id
WHERE (
  wi.submitted_by = auth.uid()
  OR EXISTS (
    SELECT 1 FROM profiles me
    WHERE  me.id         = auth.uid()
      AND  wpc.record_id = me.employee_id
  )
)
ORDER BY wi.id, wi.updated_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'One row per workflow instance for the current user. '
  'Mig 531: DISTINCT ON (wi.id) fixes ROLE fan-out duplicates. '
  'Added current_step_name + pending_task_count; current_approver_name is NULL '
  'when multiple tasks are pending (ROLE step) — UI falls back to step name.';
