-- =============================================================================
-- Migration 198: vw_wf_pending_tasks — use live proposed_data as metadata
--
-- PROBLEM
-- ───────
-- wf_approver_update_pending_changes (mig 193) updates
-- workflow_pending_changes.proposed_data when an approver edits the proposed
-- values mid-flight. But vw_wf_pending_tasks (mig 197) exposes wi.metadata,
-- which is snapshotted at submission time and never updated. After an approver
-- saves changes, re-loading the task still shows the original values.
--
-- FIX
-- ───
-- Replace wi.metadata with:
--   COALESCE(wpc.proposed_data, wi.metadata)
--
-- For profile_* and all non-expense modules:
--   wpc (workflow_pending_changes) is always LEFT JOINed via wpc.id = wi.record_id.
--   After wf_approver_update_pending_changes runs, wpc.proposed_data holds the
--   latest approved values — the view will now surface them.
--
-- For expense_reports:
--   wi.record_id points to the expense_report row, not a wpc row.
--   The LEFT JOIN produces no wpc match → wpc.proposed_data = NULL →
--   COALESCE falls back to wi.metadata. Expense behaviour is unchanged.
--
-- IMPACT
-- ──────
-- ApproverInbox read-mode now shows the latest proposed values after an edit.
-- The WorkflowTimeline and history views are unaffected (they read from
-- workflow_action_log, not the view).
-- =============================================================================


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
  -- Use live proposed_data when available (approver may have edited it).
  -- Falls back to wi.metadata for expense_reports (no wpc row).
  COALESCE(wpc.proposed_data, wi.metadata)     AS metadata,
  wpc.current_data,
  wi.submitted_by,
  e_sub.name                                   AS submitted_by_name,
  e_sub.business_email                         AS submitted_by_email,
  wt.due_at,
  wt.created_at                                AS task_created_at,
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
WHERE      wt.status  = 'pending'
  AND      wi.status  = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Tasks pending action by the current user. '
  'metadata (mig 198) now uses COALESCE(wpc.proposed_data, wi.metadata) so '
  'mid-flight edits by approvers (wf_approver_update_pending_changes) are '
  'immediately visible without re-submission. '
  'step_allow_edit (mig 197) exposes ws.allow_edit. '
  'current_data (mig 176) exposes the before-snapshot for profile module diffs. '
  'sla_status is computed from due_at.';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_pending_tasks'
ORDER  BY ordinal_position;

-- Expected columns (in order):
--   task_id, instance_id, assigned_to, step_name, step_allow_edit,
--   step_order, template_code, template_name, module_code, record_id,
--   metadata, current_data, submitted_by, submitted_by_name,
--   submitted_by_email, due_at, task_created_at, sla_status

-- =============================================================================
-- END OF MIGRATION 198
--
-- After applying:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
-- =============================================================================
