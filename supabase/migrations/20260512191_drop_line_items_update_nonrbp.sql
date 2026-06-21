-- =============================================================================
-- Migration 191: Drop non-rbp line_items_update policy (migration 190 artefact)
--
-- BACKGROUND
-- ──────────
-- Migration 190 created/rebuilt line_items_update using has_permission() as
-- the permission gate.  has_permission() joins role_permissions (dropped in
-- migration 146) — so it always errors or returns false at runtime, making the
-- approver and ESS paths in that policy completely inoperative.
--
-- rbp_line_items_update (migration 084) already covers every case correctly
-- via user_can(), which reads permission_set_assignments directly:
--
--   • ESS (own report, any permitted status):
--       user_can('expense_reports', 'edit', er.employee_id)
--       AND er.employee_id = get_my_employee_id()
--
--   • Approver (active assignee + allow_edit gate):
--       user_can('expense_reports', 'edit', er.employee_id)
--       AND wi.status = 'in_progress'
--       AND wt.assigned_to = auth.uid()
--       AND wt.status = 'pending'
--       AND ws.allow_edit = true
--
-- Dropping line_items_update removes dead code, leaves rbp_line_items_update
-- as the sole UPDATE policy, and eliminates the runtime error risk from
-- the broken has_permission() reference.
--
-- FRONTEND CHANGE DEPLOYED TOGETHER
-- ──────────────────────────────────
-- WorkflowReview.tsx canEditMidFlight gate updated from can('expense.edit')
-- → can('expense_reports.edit') in the same deployment (same permission code
-- mismatch that migration 190 was trying to fix at the DB layer).
-- =============================================================================


DROP POLICY IF EXISTS line_items_update ON line_items;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm the non-rbp policy is gone
SELECT COUNT(*) = 0 AS nonrbp_policy_dropped
FROM   pg_policies
WHERE  tablename  = 'line_items'
  AND  policyname = 'line_items_update';

-- 2. Confirm rbp_line_items_update still exists and is the sole UPDATE policy
SELECT policyname, cmd
FROM   pg_policies
WHERE  tablename = 'line_items'
  AND  cmd       = 'UPDATE'
ORDER  BY policyname;

-- Expected: only rbp_line_items_update remains.

-- =============================================================================
-- END OF MIGRATION 191
--
-- No type regen needed — no schema changes, no new RPCs.
-- Smoke-test: Finance approver on a step with allow_edit=ON should now be
-- able to save line-item notes from WorkflowReview.
-- =============================================================================
