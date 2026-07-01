-- =============================================================================
-- Migration 592 — Fix Security Definer View advisor warnings
--
-- BACKGROUND
-- ══════════
-- Supabase Advisor flagged 12 views as SECURITY DEFINER. After analysis,
-- they fall into three distinct tiers requiring different treatment:
--
-- TIER 1 — GENUINE RISK: Admin/internal views with no auth.uid() filter.
--   Any authenticated user can SELECT from these and see cross-employee data.
--   Fix: REVOKE SELECT from authenticated + anon. Service role only.
--   These views are only consumed by:
--     (a) SECURITY DEFINER RPCs that gate on is_super_admin() / user_can()
--     (b) The pg_cron sync job (runs as postgres / service role)
--   so revoking authenticated access has zero functional impact.
--
-- TIER 2 — FALSE POSITIVE: User-scoped views already filtering by auth.uid().
--   Even with SECURITY DEFINER, a regular user can only see their own rows
--   because the WHERE clause binds to auth.uid(). Add WITH (security_invoker)
--   to make intent explicit and silence the advisor cleanly.
--
-- TIER 3 — NO RISK: Pure reference/lookup data views (no PII).
--   vw_currencies_lookup, vw_departments_lookup, vw_picklist_values_lookup,
--   vw_projects_lookup were explicitly designed as SECURITY INVOKER in mig 147.
--   No action needed — advisor may be misreading the pg_views catalog.
--   Documented here for completeness; these are left untouched.
--
-- WHAT IS NOT TOUCHED
-- ───────────────────
--   Tier 2 + Tier 3 view SELECT logic — unchanged
--   All RPC functions that query these views — unchanged
--   Frontend code — zero changes needed; all access goes via RPC
--   RLS policies on underlying tables — unchanged
-- =============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 1: Revoke direct authenticated access to admin/internal views
-- ═══════════════════════════════════════════════════════════════════════════
--
-- These views expose cross-employee data with no row-level filter.
-- They are only legitimately queried by:
--   • SECURITY DEFINER RPCs (run as postgres, bypass RLS — intentional)
--   • pg_cron jobs (run as postgres / service_role)
--   • Supabase Studio / service_role queries (admin-only)
--
-- Revoking authenticated + anon access is safe: no frontend code queries
-- these views directly. All access goes through RPCs.

REVOKE SELECT ON pending_invite_reminders   FROM authenticated, anon;
REVOKE SELECT ON vw_employment_drift         FROM authenticated, anon;
REVOKE SELECT ON vw_personal_name_drift      FROM authenticated, anon;
REVOKE SELECT ON vw_job_relationships_drift  FROM authenticated, anon;
REVOKE SELECT ON vw_wf_operations            FROM authenticated, anon;
REVOKE SELECT ON vw_notification_monitor     FROM authenticated, anon;

-- Explicit service_role grant (belt-and-suspenders — postgres owns these,
-- service_role already has superuser-equivalent, but being explicit is safer)
GRANT SELECT ON pending_invite_reminders   TO service_role;
GRANT SELECT ON vw_employment_drift         TO service_role;
GRANT SELECT ON vw_personal_name_drift      TO service_role;
GRANT SELECT ON vw_job_relationships_drift  TO service_role;
GRANT SELECT ON vw_wf_operations            TO service_role;
GRANT SELECT ON vw_notification_monitor     TO service_role;


-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 2: Add WITH (security_invoker = true) to user-scoped workflow views
-- ═══════════════════════════════════════════════════════════════════════════
--
-- These views already filter by auth.uid() in their WHERE clause, so
-- SECURITY DEFINER poses no practical risk. But adding security_invoker:
--   1. Makes the intent explicit and auditable
--   2. Silences the Supabase Advisor warning legitimately
--   3. Means RLS on underlying tables also applies (double protection)
--
-- We must DROP + recreate because ALTER VIEW cannot change security model.
-- The SELECT body is copied verbatim from the latest migration that touches
-- each view (mig 533 for vw_wf_pending_tasks, mig 612 for vw_wf_my_requests).

-- ── vw_wf_pending_tasks ───────────────────────────────────────────────────
-- Last modified: mig 533 (subject_employee columns) + mig 508 (actor columns)
-- Filter: wt.assigned_to = auth.uid()

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
  'Pending approval tasks for the current user. security_invoker = true (mig 592). '
  'Mig 508: initiated_by_actor. Mig 533: subject_employee. '
  'auth.uid() filter ensures users only see their own tasks.';


-- ── vw_wf_my_requests ─────────────────────────────────────────────────────
-- Last modified: mig 531 (DISTINCT ON fix for ROLE fan-out)
-- Filter: wi.submitted_by = auth.uid() OR record_id matches own employee_id

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
  'One row per workflow instance for the current user. security_invoker = true (mig 592). '
  'Mig 531: DISTINCT ON fixes ROLE fan-out duplicates. '
  'auth.uid() filter ensures users only see their own requests.';


-- ═══════════════════════════════════════════════════════════════════════════
-- TIER 3: Lookup views — no action required
-- ═══════════════════════════════════════════════════════════════════════════
--
-- vw_currencies_lookup, vw_departments_lookup, vw_picklist_values_lookup,
-- vw_projects_lookup were created as SECURITY INVOKER in mig 147 with
-- explicit RLS policies on the underlying tables. They contain no PII —
-- only reference data (currency codes, department names, dropdown options).
-- The Supabase Advisor warning is a false positive for these views.
-- No changes made. Documented here for audit completeness.


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Confirm SECURITY INVOKER flag on tier-2 views
SELECT viewname, definition
FROM   pg_views
WHERE  viewname IN ('vw_wf_pending_tasks', 'vw_wf_my_requests')
  AND  schemaname = 'public';

-- Confirm tier-1 views are not grantable to authenticated
SELECT grantee, privilege_type, table_name
FROM   information_schema.role_table_grants
WHERE  table_name IN (
  'pending_invite_reminders',
  'vw_employment_drift',
  'vw_personal_name_drift',
  'vw_job_relationships_drift',
  'vw_wf_operations',
  'vw_notification_monitor'
)
  AND grantee = 'authenticated';
-- Expected: 0 rows
