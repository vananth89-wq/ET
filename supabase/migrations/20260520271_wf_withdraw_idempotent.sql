-- Migration 271: Make wf_withdraw idempotent for already-withdrawn instances
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- ───────
-- When an initiator clicks "Discard Record" on a rejected hire, the RPC
-- succeeds on the first call and sets the instance status to 'withdrawn'.
-- However, a second call can fire in rapid succession because the Realtime
-- subscription (listening on workflow_instances) re-renders the component
-- before the UI has fully navigated away, causing the action handler to
-- execute twice.  The second call throws:
--
--   wf_withdraw: only in_progress, awaiting_clarification, or rejected
--   instances can be withdrawn (current status: withdrawn)
--
-- FIX
-- ───
-- Add an idempotency guard: if the instance is already 'withdrawn', silently
-- return.  This also protects against accidental double-submits in any other
-- withdrawal path (send-back, in-progress).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_withdraw(
  p_instance_id uuid,
  p_reason      text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance workflow_instances%ROWTYPE;
BEGIN
  SELECT * INTO v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_withdraw: instance % not found', p_instance_id;
  END IF;

  -- ── Idempotency guard ────────────────────────────────────────────────────
  -- If already withdrawn (e.g. a second call fired before navigation completed)
  -- treat as a no-op rather than raising an error.
  IF v_instance.status = 'withdrawn' THEN
    RETURN;
  END IF;

  -- Accept all three non-terminal active states:
  --   in_progress            — normal in-flight withdrawal
  --   awaiting_clarification — withdrawing after a send-back
  --   rejected               — initiator discarding a hard-rejected hire
  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification', 'rejected') THEN
    RAISE EXCEPTION
      'wf_withdraw: only in_progress, awaiting_clarification, or rejected instances '
      'can be withdrawn (current status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- Cancel any remaining pending tasks.
  -- No-op for awaiting_clarification (tasks already 'returned') and
  -- rejected (tasks already 'cancelled' / 'rejected' by the engine).
  UPDATE workflow_tasks
  SET    status     = 'cancelled',
         updated_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- Transition instance to withdrawn
  UPDATE workflow_instances
  SET    status     = 'withdrawn',
         updated_at = now()
  WHERE  id = p_instance_id;

  -- Log the withdrawal
  INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
  VALUES (p_instance_id, auth.uid(), 'withdrawn', p_reason);

  -- Sync module record:
  --   expense_reports → reset to 'draft' (editable again)
  --   profile_*       → set wpc.status = 'withdrawn'
  --   employee_hire   → soft-delete (deleted_at = now())
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'draft');
END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid, text) IS
  'Allows the submitter (or admin) to withdraw a workflow request. '
  'Mig 245: extended from in_progress-only to also accept awaiting_clarification. '
  'Mig 269: also accepts rejected so initiators can discard hard-rejected hires. '
  'Mig 271: idempotent — already-withdrawn instances are silently ignored '
  'to handle rapid double-calls from Realtime-triggered re-renders.';
