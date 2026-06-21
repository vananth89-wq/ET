-- =============================================================================
-- Migration 199: vw_wf_my_requests — use live proposed_data as metadata
--
-- PROBLEM
-- ───────
-- vw_wf_my_requests (mig 179) exposes wi.metadata (the original submission
-- snapshot). An approver can edit proposed_data mid-flight via
-- wf_approver_update_pending_changes (mig 193). When the approver then sends
-- the item back to the initiator (wf_return_to_initiator), the submitter sees
-- the Sent Back tab — but the ProfileEnrichment reads task.metadata (from
-- vw_wf_my_requests.metadata = wi.metadata) which is still the original data.
-- The submitter cannot tell what the approver changed, and will edit/resubmit
-- from stale proposed values.
--
-- FIX
-- ───
-- Replace wi.metadata with COALESCE(wpc.proposed_data, wi.metadata).
-- Add a LEFT JOIN to workflow_pending_changes on wpc.id = wi.record_id.
--
-- For profile_* modules:
--   wpc always exists (record_id = wpc.id). If the approver edited it,
--   wpc.proposed_data holds the updated values. COALESCE surfaces them.
--
-- For expense_reports:
--   wi.record_id points to the expense_reports row, not a wpc row.
--   LEFT JOIN produces no match → wpc.proposed_data = NULL →
--   COALESCE falls back to wi.metadata. Unchanged.
--
-- This mirrors the same fix applied to vw_wf_pending_tasks in mig 198.
-- =============================================================================


DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  -- Live proposed values: if an approver edited proposed_data before returning
  -- to initiator, the submitter now sees the latest values, not the stale snapshot.
  -- Falls back to wi.metadata for expense_reports (no wpc row).
  COALESCE(wpc.proposed_data, wi.metadata)  AS metadata,
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  -- Current pending task (NULL when completed / returned / rejected)
  current_task.assigned_to   AS current_approver_id,
  e_apr.name                 AS current_approver_name,
  current_task.due_at        AS current_task_due,
  -- Clarification request details (populated when status = 'awaiting_clarification')
  clarif.notes               AS clarification_message,
  e_clarif.name              AS clarification_from,
  clarif.created_at          AS clarification_at
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
-- Live proposed_data from workflow_pending_changes (mig 199)
LEFT JOIN  workflow_pending_changes wpc ON wpc.id = wi.record_id
-- Current pending task
LEFT JOIN  workflow_tasks      current_task
             ON  current_task.instance_id = wi.id
             AND current_task.step_order  = wi.current_step
             AND current_task.status      = 'pending'
LEFT JOIN  profiles            p_apr ON p_apr.id        = current_task.assigned_to
LEFT JOIN  employees           e_apr ON e_apr.id        = p_apr.employee_id
-- Latest clarification request (most recent returned_to_initiator action)
LEFT JOIN LATERAL (
  SELECT wal.notes, wal.actor_id, wal.created_at
  FROM   workflow_action_log wal
  WHERE  wal.instance_id = wi.id
    AND  wal.action      = 'returned_to_initiator'
  ORDER  BY wal.created_at DESC
  LIMIT  1
) clarif ON true
LEFT JOIN  profiles            p_clarif ON p_clarif.id   = clarif.actor_id
LEFT JOIN  employees           e_clarif ON e_clarif.id   = p_clarif.employee_id
WHERE      wi.submitted_by = auth.uid()
ORDER BY   wi.updated_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'All workflow instances submitted by the current user. '
  'metadata (mig 199) now uses COALESCE(wpc.proposed_data, wi.metadata) so '
  'approver mid-flight edits (wf_approver_update_pending_changes) are visible '
  'to the submitter in the Sent Back inbox. '
  'Includes current approver, SLA due date, and clarification message '
  'when status = awaiting_clarification.';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT column_name
FROM   information_schema.columns
WHERE  table_name = 'vw_wf_my_requests'
ORDER  BY ordinal_position;

-- =============================================================================
-- END OF MIGRATION 199
--
-- After applying:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
-- =============================================================================
