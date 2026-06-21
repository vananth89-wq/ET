-- =============================================================================
-- Migration 211: wf_admin_reject — permanent final rejection by admin
--
-- PROBLEM
-- ───────
-- wf_admin_decline() was labelled "Decline" in the UI but its behaviour is
-- "return to submitter for clarification" (awaiting_clarification). Admins
-- who want a TRUE final rejection had no dedicated action.
--
-- FIX
-- ───
-- New function wf_admin_reject():
--   • Cancels all pending tasks
--   • Sets instance status = 'cancelled'  (permanent, not resubmittable)
--   • Sets completed_at
--   • Syncs the module status to 'rejected'
--   • Logs 'admin_rejected' action
--   • Notifies the submitter with wf.admin_rejected template
--
-- wf_admin_decline() is UNCHANGED — it continues to return the request to
-- the submitter (awaiting_clarification). The UI is updated to call it
-- "Return to Submitter" so the distinction is clear.
--
-- NO SCHEMA CHANGES — pure function addition + notification template.
-- =============================================================================


-- ── Notification template ──────────────────────────────────────────────────
INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES (
  'wf.admin_rejected',
  'Your request has been rejected',
  'An administrator has permanently rejected your request. Reason: {{reason}}'
)
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ── wf_admin_reject ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION wf_admin_reject(
  p_instance_id uuid,
  p_reason      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  -- ── Access check ───────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_admin_reject: insufficient permissions';
  END IF;

  -- ── Reason is mandatory ────────────────────────────────────────────────────
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_admin_reject: reason is required';
  END IF;

  -- ── Load and lock instance ─────────────────────────────────────────────────
  SELECT id, submitted_by, module_code, record_id, status, current_step
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_admin_reject: instance % not found', p_instance_id;
  END IF;

  -- Allow rejection from any active-ish state (not already terminal)
  IF v_instance.status IN ('approved', 'rejected', 'cancelled', 'withdrawn') THEN
    RAISE EXCEPTION 'wf_admin_reject: instance is already closed (status: %)',
                    v_instance.status;
  END IF;

  -- ── Cancel all pending tasks ───────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         notes    = p_reason,
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- ── Close instance permanently ─────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'cancelled',
         updated_at   = now(),
         completed_at = now()
  WHERE  id = p_instance_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    p_instance_id,
    auth.uid(),
    'admin_rejected',
    v_instance.current_step,
    p_reason,
    jsonb_build_object('reason', p_reason)
  );

  -- ── Sync module status ─────────────────────────────────────────────────────
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'rejected'
  );

  -- ── Notify submitter ───────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.admin_rejected',
    v_instance.submitted_by,
    jsonb_build_object('reason', p_reason)
  );
END;
$$;

COMMENT ON FUNCTION wf_admin_reject(uuid, text) IS
  'Admin-only: permanently reject a workflow instance. '
  'All pending tasks are cancelled; instance status = cancelled (terminal). '
  'The submitter cannot resubmit after this action. '
  'For a non-terminal return that allows resubmission, use wf_admin_decline().';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc
WHERE  proname IN ('wf_admin_decline', 'wf_admin_reject')
ORDER BY proname;
