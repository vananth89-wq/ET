-- Migration 533: Add subject_employee_name to vw_wf_pending_tasks
--
-- Bug: "Submitted by Safia on behalf of Safia" when HR submits a termination
-- for another employee. The "on behalf of" was reading submitted_by_name (the
-- HR actor) instead of the subject employee's name.
--
-- Fix: add subject_profile_id + subject_employee_name from workflow_instances.
-- The UI uses subject_employee_name for the "on behalf of" label.
--
-- Base: mig 508 (most recent prior rewrite). All mig 508 columns preserved:
--   • COALESCE(wpc.proposed_data, wi.metadata) AS metadata  (mig 198)
--   • wpc.current_data                                       (mig 176)
--   • ws.allow_edit AS step_allow_edit                       (mig 197)
--   • initiated_by_actor_id / initiated_by_actor_name        (mig 508)

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
  -- ── subject employee (mig 533) ──────────────────────────────────────────
  -- The person this workflow is about. For HR-initiated submissions this
  -- differs from submitted_by (the actor). Used for "on behalf of" display.
  wi.subject_profile_id,
  e_subj.name                                  AS subject_employee_name,
  -- ────────────────────────────────────────────────────────────────────────
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now()                        THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours'  THEN 'due_soon'
    ELSE 'on_track'
  END                                          AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi       ON wi.id          = wt.instance_id
JOIN       workflow_steps      ws       ON ws.id          = wt.step_id
JOIN       workflow_templates  tpl      ON tpl.id         = wi.template_id
JOIN       profiles            sub      ON sub.id         = wi.submitted_by
LEFT JOIN  employees           e_sub    ON e_sub.id       = sub.employee_id
LEFT JOIN  workflow_pending_changes wpc ON wpc.id         = wi.record_id
-- Actor who submitted on behalf of subject (NULL for self-service)
LEFT JOIN  profiles            p_actor  ON p_actor.id     = wi.initiated_by_actor_id
LEFT JOIN  employees           e_actor  ON e_actor.id     = p_actor.employee_id
-- Subject employee (person the workflow is about)
LEFT JOIN  profiles            p_subj   ON p_subj.id      = wi.subject_profile_id
LEFT JOIN  employees           e_subj   ON e_subj.id      = p_subj.employee_id
WHERE      wt.status      = 'pending'
  AND      wi.status      = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Pending approval tasks for the current user. '
  'Mig 508: initiated_by_actor_id + initiated_by_actor_name. '
  'Mig 533: subject_profile_id + subject_employee_name for correct on-behalf-of display.';
