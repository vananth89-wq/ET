-- =============================================================================
-- Migration 193: wf_approver_update_pending_changes RPC
--
-- PURPOSE
-- ───────
-- Allow an active-step approver to overwrite proposed_data in
-- workflow_pending_changes when the step has allow_edit = true.
--
-- WHY AN RPC IS NEEDED
-- ────────────────────
-- wpc_update RLS (migration 129) gates UPDATE on user_can('wf_manage','edit',NULL).
-- Regular approvers don't hold wf_manage.edit — they only have module-level
-- permissions (e.g. expense_reports.approve).  A SECURITY DEFINER function
-- can bypass RLS and enforce the business guard itself.
--
-- BUSINESS GUARDS (all must pass)
-- ────────────────────────────────
-- 1. The caller is an active task assignee on the instance:
--      workflow_tasks WHERE instance_id = p_instance_id
--                       AND assigned_to = auth.uid()
--                       AND status = 'pending'
-- 2. The step for that task has allow_edit = true:
--      workflow_steps WHERE id = wt.step_id AND allow_edit = true
-- 3. The instance exists and is in_progress.
--
-- WHAT IT DOES
-- ────────────
-- UPDATE workflow_pending_changes
--   SET proposed_data = p_proposed_data, updated_at = now()
--   WHERE instance_id = p_instance_id;
--
-- Returns void on success; raises an exception on any guard failure.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_approver_update_pending_changes(
  p_instance_id   uuid,
  p_proposed_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_task_id   uuid;
  v_allow_edit boolean;
  v_status    text;
BEGIN
  -- ── Guard 1: caller has an active pending task on this instance ───────────
  SELECT wt.id, ws.allow_edit
  INTO   v_task_id, v_allow_edit
  FROM   workflow_tasks  wt
  JOIN   workflow_steps  ws ON ws.id = wt.step_id
  WHERE  wt.instance_id  = p_instance_id
    AND  wt.assigned_to  = auth.uid()
    AND  wt.status       = 'pending'
  LIMIT 1;

  IF v_task_id IS NULL THEN
    RAISE EXCEPTION 'You are not an active approver for this workflow instance.';
  END IF;

  -- ── Guard 2: step must have allow_edit = true ─────────────────────────────
  IF NOT COALESCE(v_allow_edit, false) THEN
    RAISE EXCEPTION 'Mid-flight editing is not enabled for this approval step.';
  END IF;

  -- ── Guard 3: instance must be in_progress ────────────────────────────────
  SELECT status INTO v_status
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF v_status IS DISTINCT FROM 'in_progress' THEN
    RAISE EXCEPTION 'Workflow instance is not currently in progress (status: %).', v_status;
  END IF;

  -- ── Perform the update (bypasses RLS via SECURITY DEFINER) ───────────────
  UPDATE workflow_pending_changes
  SET
    proposed_data = p_proposed_data,
    updated_at    = now()
  WHERE instance_id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No pending changes record found for this instance.';
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_approver_update_pending_changes(uuid, jsonb) IS
  'Allows an active-step approver to overwrite proposed_data in workflow_pending_changes. '
  'Guards: caller must be a pending task assignee AND the step must have allow_edit=true AND instance must be in_progress. '
  'SECURITY DEFINER — bypasses wpc_update RLS which gates on wf_manage.edit. '
  'Migration 193.';

GRANT EXECUTE ON FUNCTION wf_approver_update_pending_changes(uuid, jsonb) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Function exists with correct signature
SELECT
  proname,
  prosrc LIKE '%auth.uid()%'     AS checks_auth,
  prosrc LIKE '%allow_edit%'     AS checks_allow_edit,
  prosrc LIKE '%in_progress%'    AS checks_instance_status
FROM pg_proc
WHERE proname = 'wf_approver_update_pending_changes';

-- 2. Grant exists
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name = 'wf_approver_update_pending_changes'
  AND  grantee      = 'authenticated';

-- =============================================================================
-- END OF MIGRATION 193
--
-- After applying:
--   1. npx supabase gen types typescript … > src/types/database.types.ts
--   2. ApproverInbox.tsx — wire the edit UI for profile module tasks in DetailPanel
-- =============================================================================
