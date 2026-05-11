-- =============================================================================
-- Migration 169: workflow_steps — approver assignee SELECT policy
--
-- PROBLEM
-- ───────
-- Migration 153 tightened workflow_steps SELECT to:
--   user_can('wf_templates', 'view', NULL)
--
-- This was correct for preventing ESS users from browsing template config
-- directly. The ESS pre-submit preview was fixed separately by the SECURITY
-- DEFINER RPC get_workflow_participants() (mig 166–168).
--
-- However, mig 153 also blocked APPROVERS from reading the step they are
-- actively assigned to review. Approvers have wf_inbox.view but not
-- wf_templates.view, so WorkflowReview.tsx's nested join:
--
--   supabase
--     .from('workflow_tasks')
--     .select('workflow_steps ( allow_edit )')   -- ← nested join via step_id FK
--     .eq('id', myTask.taskId)
--
-- silently returns null for the workflow_steps columns. This collapses the
-- dual-control gate:
--   const canEditMidFlight = stepAllowEdit && canEditOnApproval;
--   // stepAllowEdit is always false  ↑  even when the step sets allow_edit=true
--
-- An approver reviewing their assigned task genuinely SHOULD be able to read
-- that step's flags — this is logically correct access, not an escalation.
--
-- SOLUTION
-- ────────
-- Add a second SELECT policy on workflow_steps (PostgreSQL evaluates multiple
-- SELECT policies with OR — a row is visible if ANY policy permits it):
--
--   wf_steps_assignee_read:
--   USING EXISTS (
--     SELECT 1 FROM workflow_tasks wt
--     WHERE wt.step_id     = id          -- the step being read
--       AND wt.assigned_to = auth.uid()  -- caller has a task for it
--   )
--
-- Access is scoped to steps the caller is actually assigned to — no broader
-- template data is exposed. write policies (INSERT / UPDATE / DELETE) are
-- unchanged; they remain gated on user_can('wf_templates','edit',NULL).
--
-- WHY RLS POLICY INSTEAD OF SECURITY DEFINER RPC?
-- ──────────────────────────────────────────────────
-- The SECURITY DEFINER pattern (used by get_workflow_participants) is the
-- right tool when a user fundamentally should NOT have direct table access
-- but needs computed/aggregated data from it (ESS previewing a template).
--
-- Here the approver genuinely SHOULD be able to read the step — mig 153
-- over-reached. A targeted RLS policy restores exactly the right level of
-- access with no UI code changes, no RPC overhead, and clearer intent.
-- The existing nested join in WorkflowReview.tsx just works.
--
-- IMPACT
-- ──────
-- Before: stepAllowEdit always false for approvers → canEditMidFlight=false
--         → inline line-item editing disabled in WorkflowReview even when
--           the template step sets allow_edit = true.
-- After:  stepAllowEdit correctly reflects workflow_steps.allow_edit →
--         inline editing enabled/disabled per the template step config.
--
-- No UI code changes needed — the existing Supabase nested join resolves.
-- =============================================================================


-- Add SELECT policy: approver can read the step they are assigned to
CREATE POLICY "wf_steps_assignee_read" ON workflow_steps
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      WHERE  wt.step_id     = workflow_steps.id
        AND  wt.assigned_to = auth.uid()
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm both SELECT policies now exist on workflow_steps
SELECT policyname, cmd, qual
FROM   pg_policies
WHERE  tablename  = 'workflow_steps'
  AND  schemaname = 'public'
ORDER  BY policyname;

-- Expected output (two SELECT policies):
--   wf_steps_assignee_read   | SELECT | EXISTS (SELECT 1 FROM workflow_tasks ...)
--   <existing mig-153 policy>| SELECT | user_can('wf_templates','view',NULL)

-- 2. Smoke-test: as an approver user, this should now return a row
--    (run in Supabase SQL editor as the approver's auth context):
-- SELECT allow_edit
-- FROM   workflow_steps ws
-- WHERE  EXISTS (
--   SELECT 1 FROM workflow_tasks wt
--   WHERE wt.step_id = ws.id AND wt.assigned_to = auth.uid()
-- );

-- =============================================================================
-- END OF MIGRATION 169
--
-- No type regen needed — no new RPC or table columns added.
-- No UI changes needed — WorkflowReview.tsx nested join resolves automatically.
-- =============================================================================
