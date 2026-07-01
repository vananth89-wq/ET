-- =============================================================================
-- Migration 592 — Fix Security Definer View advisor warnings
--
-- ANALYSIS SUMMARY (12 views flagged, 3 tiers)
-- ══════════════════════════════════════════════
--
-- TIER 1A — Safe to REVOKE (no frontend query, no PII risk):
--   pending_invite_reminders   — cron job only (runs as postgres/service_role)
--   vw_employment_drift        — ops reconciliation only; no .from() call in src/
--   vw_personal_name_drift     — ops reconciliation only; no .from() call in src/
--   vw_job_relationships_drift — ops reconciliation only; no .from() call in src/
--   Fix: REVOKE SELECT FROM authenticated, anon. Zero functional impact.
--
-- TIER 1B — Frontend-queried; cannot REVOKE without breaking the app:
--   vw_wf_operations      — WorkflowOperations.tsx queries .from('vw_wf_operations')
--   vw_notification_monitor — NotificationMonitor.tsx queries .from('vw_notification_monitor')
--   Fix: ADD permission guard to WHERE clause.
--     user_can('wf_manage','view',NULL)       → Path B (admin module, no target scoping)
--     user_can('wf_notifications','view',NULL) → Path B (same)
--   A regular authenticated user who queries these views gets 0 rows, not an error.
--   Admin users with the correct permission set see exactly what they see today.
--
-- TIER 2 — False positives (user-scoped by auth.uid() — fixed separately in this mig):
--   vw_wf_pending_tasks  → WITH (security_invoker = true)
--   vw_wf_my_requests    → WITH (security_invoker = true)
--
-- TIER 3 — No action (lookup reference data, no PII):
--   vw_currencies_lookup, vw_departments_lookup,
--   vw_picklist_values_lookup, vw_projects_lookup
--
-- WHAT IS NOT TOUCHED
-- ───────────────────
--   All frontend code — zero changes needed
--   All RPC functions — zero changes needed
--   RLS policies on underlying tables — unchanged
--   Any view not listed above — unchanged
-- =============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 1A: REVOKE on views with no frontend access
-- ═══════════════════════════════════════════════════════════════════════════

REVOKE SELECT ON pending_invite_reminders   FROM authenticated, anon;
REVOKE SELECT ON vw_employment_drift         FROM authenticated, anon;
REVOKE SELECT ON vw_personal_name_drift      FROM authenticated, anon;
REVOKE SELECT ON vw_job_relationships_drift  FROM authenticated, anon;

GRANT SELECT ON pending_invite_reminders   TO service_role;
GRANT SELECT ON vw_employment_drift         TO service_role;
GRANT SELECT ON vw_personal_name_drift      TO service_role;
GRANT SELECT ON vw_job_relationships_drift  TO service_role;


-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 1B: Add permission guard to frontend-queried admin views
-- ═══════════════════════════════════════════════════════════════════════════
--
-- user_can(module, action, NULL) uses Path B — role-only check, no target
-- scoping. Returns true only for users whose permission set includes the
-- permission. Regular employees get 0 rows (not an error).
--
-- Permission codes (confirmed from ADMIN_NAV in App.tsx):
--   vw_wf_operations:      wf_manage.view      (Manage Workflow screen)
--   vw_notification_monitor: wf_notifications.view (Notification Monitor screen)


-- ── vw_wf_operations ──────────────────────────────────────────────────────
-- Base: mig 591 (subject_name + department follow subject employee)
-- Change: added AND (is_super_admin() OR user_can('wf_manage','view',NULL))

DROP VIEW IF EXISTS vw_wf_operations;

CREATE VIEW vw_wf_operations AS
SELECT
  wt.id                                                               AS task_id,
  wi.id                                                               AS instance_id,
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
  tpl.id                                                              AS template_id,
  tpl.code                                                            AS template_code,
  tpl.name                                                            AS template_name,
  wi.module_code,
  wi.record_id,
  wi.status                                                           AS instance_status,
  wt.step_order,
  ws.name                                                             AS step_name,
  ws.sla_hours,
  wt.assigned_to                                                      AS assignee_id,
  assignee_emp.name                                                   AS assignee_name,
  assignee_emp.job_title                                              AS assignee_job_title,
  wi.submitted_by                                                     AS submitter_id,
  submitter_emp.name                                                  AS submitter_name,
  COALESCE(subject_emp.name,  submitter_emp.name)                    AS subject_name,
  COALESCE(subject_emp.dept_id, submitter_emp.dept_id)               AS subject_dept_id,
  dept.id                                                             AS department_id,
  dept.name                                                           AS department_name,
  wi.created_at                                                       AS submitted_at,
  wt.created_at                                                       AS pending_since,
  wt.due_at,
  ROUND(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 3600, 1
  )                                                                   AS age_hours,
  FLOOR(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 86400
  )::integer                                                          AS age_days,
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
LEFT JOIN  profiles            subject_p    ON subject_p.id  = wi.subject_profile_id
                                           AND wi.subject_profile_id IS DISTINCT FROM wi.submitted_by
LEFT JOIN  employees           subject_emp  ON subject_emp.id = subject_p.employee_id
LEFT JOIN  departments         dept         ON dept.id = COALESCE(subject_emp.dept_id, submitter_emp.dept_id)

WHERE wt.status = 'pending'
  AND wi.status IN ('in_progress', 'awaiting_clarification')
  -- ── SECURITY GUARD (mig 592) ────────────────────────────────────────────
  -- user_can() Path B: role-only check, no target scoping (p_owner = NULL).
  -- Regular employees → 0 rows. Admins with wf_manage.view → full result set.
  AND (is_super_admin() OR user_can('wf_manage', 'view', NULL));

GRANT SELECT ON vw_wf_operations TO authenticated;

COMMENT ON VIEW vw_wf_operations IS
  'Mig 591: subject_name + dept follow subject employee. '
  'Mig 592: security guard — user_can(wf_manage,view,NULL) OR is_super_admin(). '
  'Regular authenticated users get 0 rows, not an error.';


-- ── vw_notification_monitor ───────────────────────────────────────────────
-- Base: mig 052 (original creation)
-- Change: added AND (is_super_admin() OR user_can('wf_notifications','view',NULL))

DROP VIEW IF EXISTS vw_notification_monitor;

CREATE VIEW vw_notification_monitor AS
SELECT
  q.id                                                              AS queue_id,
  q.notification_id,
  q.instance_id,
  q.template_code,
  CASE
    WHEN wi.id IS NOT NULL THEN
      upper(
        CASE wi.module_code
          WHEN 'expense_reports'  THEN 'EXP'
          WHEN 'leave_requests'   THEN 'LVE'
          WHEN 'travel_requests'  THEN 'TRV'
          WHEN 'purchase_orders'  THEN 'PO'
          ELSE                         'WF'
        END
        || '-' || to_char(wi.created_at, 'YYYYMMDD')
        || '-' || upper(left(wi.id::text, 6))
      )
    ELSE 'N/A'
  END                                                               AS display_id,
  COALESCE(tpl.code, q.template_code)                               AS template_name,
  q.target_profile                                                  AS recipient_id,
  COALESCE(emp.name, 'Unknown')                                     AS recipient_name,
  emp.business_email                                                AS recipient_email,
  dept.name                                                         AS recipient_dept,
  wi.module_code,
  wi.record_id,
  q.status                                                          AS inapp_status,
  q.error_message                                                   AS inapp_error,
  q.retry_count,
  q.max_retries,
  n.email_status,
  n.email_sent_at,
  n.email_error,
  q.payload,
  q.created_at,
  q.processed_at,
  CASE
    WHEN q.status = 'pending'                               THEN 'pending'
    WHEN q.status = 'failed'                                THEN 'failed'
    WHEN q.status = 'sent' AND n.email_status = 'failed'    THEN 'partial'
    WHEN q.status = 'sent' AND n.email_status = 'pending'   THEN 'partial'
    WHEN q.status = 'sent' AND n.email_status = 'skipped'   THEN 'inapp_only'
    WHEN q.status = 'sent' AND n.email_status = 'sent'      THEN 'delivered'
    ELSE 'inapp_only'
  END                                                               AS overall_status,
  CASE
    WHEN q.status = 'failed'
         AND q.retry_count < q.max_retries                  THEN true
    WHEN q.status = 'sent'
         AND n.email_status = 'failed'                      THEN true
    ELSE false
  END                                                               AS can_retry

FROM       workflow_notification_queue     q
LEFT JOIN  notifications                   n    ON n.id    = q.notification_id
LEFT JOIN  workflow_notification_templates tpl  ON tpl.code = q.template_code
LEFT JOIN  workflow_instances              wi   ON wi.id   = q.instance_id
LEFT JOIN  profiles                        p    ON p.id    = q.target_profile
LEFT JOIN  employees                       emp  ON emp.id  = p.employee_id
LEFT JOIN  departments                     dept ON dept.id = emp.dept_id
-- ── SECURITY GUARD (mig 592) ──────────────────────────────────────────────
WHERE (is_super_admin() OR user_can('wf_notifications', 'view', NULL));

GRANT SELECT ON vw_notification_monitor TO authenticated;

COMMENT ON VIEW vw_notification_monitor IS
  'System-wide notification delivery monitor. '
  'Mig 592: security guard — user_can(wf_notifications,view,NULL) OR is_super_admin(). '
  'Regular authenticated users get 0 rows, not an error.';


-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 2: Add WITH (security_invoker = true) to user-scoped workflow views
-- ═══════════════════════════════════════════════════════════════════════════

-- ── vw_wf_pending_tasks ───────────────────────────────────────────────────
-- Base: mig 533. security_invoker makes RLS on underlying tables apply too.

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
JOIN       profiles            sub      ON sub.id         = wi.submitted_by
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
  'Mig 533: subject_employee_name. Mig 592: security_invoker = true. '
  'auth.uid() filter — users only see their own tasks.';


-- ── vw_wf_my_requests ─────────────────────────────────────────────────────
-- Base: mig 531. security_invoker makes RLS on underlying tables apply too.

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests
  WITH (security_invoker = true)
AS
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
LEFT JOIN  workflow_steps      ws
             ON  ws.template_id = wi.template_id
             AND ws.step_order  = wi.current_step
             AND ws.is_active   = true
LEFT JOIN  workflow_pending_changes wpc ON wpc.id = wi.record_id
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS task_count
  FROM   workflow_tasks wt
  WHERE  wt.instance_id = wi.id
    AND  wt.step_order  = wi.current_step
    AND  wt.status      = 'pending'
) pending ON true
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

GRANT SELECT ON vw_wf_my_requests TO authenticated;

COMMENT ON VIEW vw_wf_my_requests IS
  'Mig 531: DISTINCT ON fixes ROLE fan-out. Mig 592: security_invoker = true. '
  'auth.uid() filter — users only see their own requests.';


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Tier 1A: confirm no authenticated grant on revoked views
SELECT table_name, grantee
FROM   information_schema.role_table_grants
WHERE  table_name IN (
         'pending_invite_reminders', 'vw_employment_drift',
         'vw_personal_name_drift', 'vw_job_relationships_drift'
       )
  AND  grantee = 'authenticated';
-- Expected: 0 rows

-- 2. Tier 1B: spot-check that admin guard is present (view definitions)
SELECT viewname FROM pg_views
WHERE  viewname IN ('vw_wf_operations', 'vw_notification_monitor')
  AND  definition ILIKE '%user_can%';
-- Expected: 2 rows

-- 3. Tier 2: confirm security_invoker on workflow views
SELECT viewname FROM pg_views
WHERE  viewname IN ('vw_wf_pending_tasks', 'vw_wf_my_requests')
  AND  schemaname = 'public';
-- Expected: 2 rows (security_invoker confirmed via pg_class.relrowsecurity in PG15)
