-- =============================================================================
-- Migration 597: admin_force_complete_workflow(p_instance_id)
--
-- Recovers a stalled workflow instance where all tasks are in a terminal state
-- (approved / cancelled) but the instance is still 'in_progress' because
-- wf_advance_instance failed silently (e.g. wf_evaluate_skip_step error,
-- unresolvable approver on a phantom step, or lock contention).
--
-- What it does:
--   1. Verifies caller is super_admin.
--   2. Checks the instance IS in_progress.
--   3. Verifies there are no pending tasks (safe to complete).
--   4. Marks instance approved + completed_at = now().
--   5. Calls wf_sync_module_status so the module record (termination,
--      reversal, hire, etc.) flips to its APPROVED state.
--   6. Returns module_code + record_id so the frontend can fire the
--      appropriate Edge Function (e.g. apply-termination-reversal).
--
-- Super-admin only — no regular user can call this.
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_force_complete_workflow(
  p_instance_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance    RECORD;
  v_pending_cnt int;
BEGIN
  -- ── 1. Super-admin guard ─────────────────────────────────────────────────
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Super-admin access required.');
  END IF;

  -- ── 2. Load instance ──────────────────────────────────────────────────────
  SELECT id, status, module_code, record_id, submitted_by, current_step
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Workflow instance not found.');
  END IF;

  IF v_instance.status = 'approved' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', 'Instance already approved.');
  END IF;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Instance is in status "%s" — cannot force-complete.', v_instance.status));
  END IF;

  -- ── 3. Check no pending tasks remain ─────────────────────────────────────
  SELECT COUNT(*) INTO v_pending_cnt
  FROM   workflow_tasks
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  IF v_pending_cnt > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('%s task(s) still pending — cannot force-complete a live workflow.', v_pending_cnt));
  END IF;

  -- ── 4. Mark instance approved ─────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'approved',
         completed_at = now(),
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── 5. Log the admin action ───────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes)
  VALUES
    (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
     'Force-completed by super-admin (wf_advance_instance had stalled)');

  -- ── 6. Sync module record status ─────────────────────────────────────────
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');

  RETURN jsonb_build_object(
    'ok',          true,
    'module_code', v_instance.module_code,
    'record_id',   v_instance.record_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION admin_force_complete_workflow(uuid) IS
  'Mig 597: super-admin recovery tool. Completes a stalled in_progress instance '
  'where all tasks are terminal. Calls wf_sync_module_status so module record is '
  'flipped to APPROVED. Returns module_code + record_id for EF dispatch.';

REVOKE ALL     ON FUNCTION admin_force_complete_workflow(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION admin_force_complete_workflow(uuid) TO authenticated;
