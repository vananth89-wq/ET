-- =============================================================================
-- Migration 197: Add step_allow_edit to vw_wf_pending_tasks
--
-- PROBLEM
-- ───────
-- ApproverInbox.tsx fetches workflow_steps.allow_edit with a separate client
-- query:
--   supabase.from('workflow_tasks')
--           .select('workflow_steps ( allow_edit )')
--           .eq('id', task.taskId)
--
-- This join is subject to RLS on workflow_steps, which after migration 153
-- requires user_can('wf_templates', 'view', NULL). Approvers who hold only
-- module-level permissions (e.g. personal_info.edit) but NOT wf_templates.view
-- get a null result → stepAllowEdit stays false → Update button never renders.
--
-- Even when the approver does have wf_templates.view, the separate query is
-- wasteful — vw_wf_pending_tasks already JOINs workflow_steps (ws.name,
-- ws.step_order). Exposing ws.allow_edit here is free.
--
-- FIX
-- ───
-- Recreate vw_wf_pending_tasks adding ws.allow_edit AS step_allow_edit.
-- The view already JOINs workflow_steps unconditionally; RLS on the joined
-- table is applied to the view owner at creation time in Supabase (SECURITY
-- INVOKER), but since the view is read by authenticated users who at minimum
-- see their own task rows, and the workflow_steps join is inner (task cannot
-- exist without a step), this is equivalent to what migration 176 already
-- shipped safely.
--
-- After this migration the ApproverInbox component can read
-- task.stepAllowEdit directly from the hook instead of making a second query.
-- =============================================================================


DROP VIEW IF EXISTS vw_wf_pending_tasks;

CREATE VIEW vw_wf_pending_tasks AS
SELECT
  wt.id                  AS task_id,
  wi.id                  AS instance_id,
  wt.assigned_to,
  ws.name                AS step_name,
  ws.allow_edit          AS step_allow_edit,        -- ← mig 197
  wt.step_order,
  tpl.code               AS template_code,
  tpl.name               AS template_name,
  wi.module_code,
  wi.record_id,
  wi.metadata,
  wpc.current_data,                                  -- before/after diff (mig 176)
  wi.submitted_by,
  e_sub.name             AS submitted_by_name,
  e_sub.business_email   AS submitted_by_email,
  wt.due_at,
  wt.created_at          AS task_created_at,
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now()                        THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours'  THEN 'due_soon'
    ELSE 'on_track'
  END                    AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi    ON wi.id         = wt.instance_id
JOIN       workflow_steps      ws    ON ws.id         = wt.step_id
JOIN       workflow_templates  tpl   ON tpl.id        = wi.template_id
JOIN       profiles            sub   ON sub.id        = wi.submitted_by
LEFT JOIN  employees           e_sub ON e_sub.id      = sub.employee_id
-- pending_change.id = wi.record_id for profile_* and other non-expense modules
LEFT JOIN  workflow_pending_changes wpc ON wpc.id     = wi.record_id
WHERE      wt.status  = 'pending'
  AND      wi.status  = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Tasks pending action by the current user. '
  'step_allow_edit (mig 197) exposes ws.allow_edit so the Approver Inbox can '
  'show the Update button without a second RLS-sensitive query. '
  'current_data (mig 176) exposes the before-snapshot for profile module '
  'before/after diffs. '
  'sla_status is computed from due_at.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Column exists in view
SELECT column_name
FROM   information_schema.columns
WHERE  table_name  = 'vw_wf_pending_tasks'
  AND  column_name = 'step_allow_edit';

-- Expected: 1 row

-- 2. Full column list
SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_pending_tasks'
ORDER  BY ordinal_position;

-- =============================================================================
-- END OF MIGRATION 197
--
-- After applying:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
--
-- Frontend changes in same batch:
--   useWorkflowTasks.ts  — add stepAllowEdit to WorkflowTask, map r.step_allow_edit
--   ApproverInbox.tsx    — use task.stepAllowEdit; fix handlePanelUpdate for Pattern B
-- =============================================================================
