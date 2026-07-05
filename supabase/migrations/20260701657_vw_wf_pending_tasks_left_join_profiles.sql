-- Migration 657 — Fix vw_wf_pending_tasks: profiles JOIN must be LEFT JOIN
-- ─────────────────────────────────────────────────────────────────────────
-- Since mig 592 made this view security_invoker = true, RLS on underlying
-- tables applies with the querying user's identity.
-- profiles_select (mig 127) only allows id = auth.uid() OR is_super_admin().
-- The INNER JOIN on profiles (submitter's profile) drops any task where the
-- submitter is not the current user — i.e. any task submitted by someone else.
-- Fix: convert the profiles JOIN and its downstream employees JOIN to LEFT JOINs
-- so the task row is always returned regardless of whether the viewer can see
-- the submitter's profile.

DROP VIEW IF EXISTS vw_wf_pending_tasks;

CREATE VIEW vw_wf_pending_tasks
  WITH (security_invoker = true)
AS
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
  wi.initiated_by_actor_id,
  e_actor.name                                 AS initiated_by_actor_name,
  wi.subject_profile_id,
  e_subj.name                                  AS subject_employee_name,
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now()                        THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours'  THEN 'due_soon'
    ELSE 'on_track'
  END                                          AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi       ON wi.id          = wt.instance_id
JOIN       workflow_steps      ws       ON ws.id          = wt.step_id
JOIN       workflow_templates  tpl      ON tpl.id         = wi.template_id
-- LEFT JOIN: profiles_select RLS only allows own row; INNER JOIN would drop tasks
-- submitted by other users. NULL submitted_by_name is acceptable.
LEFT JOIN  profiles            sub      ON sub.id         = wi.submitted_by
LEFT JOIN  employees           e_sub    ON e_sub.id       = sub.employee_id
LEFT JOIN  workflow_pending_changes wpc ON wpc.id         = wi.record_id
LEFT JOIN  profiles            p_actor  ON p_actor.id     = wi.initiated_by_actor_id
LEFT JOIN  employees           e_actor  ON e_actor.id     = p_actor.employee_id
LEFT JOIN  profiles            p_subj   ON p_subj.id      = wi.subject_profile_id
LEFT JOIN  employees           e_subj   ON e_subj.id      = p_subj.employee_id
WHERE      wt.status      = 'pending'
  AND      wi.status      = 'in_progress'
  AND      wt.assigned_to = auth.uid();

GRANT SELECT ON vw_wf_pending_tasks TO authenticated;

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Pending approval tasks for the current user. '
  'Mig 533: subject_employee_name. '
  'Mig 592: security_invoker = true. '
  'Mig 657: profiles JOIN changed to LEFT JOIN — profiles_select RLS only allows '
  'own row; INNER JOIN was silently dropping tasks submitted by other users.';
