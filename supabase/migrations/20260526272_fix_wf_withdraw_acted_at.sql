-- Migration 272: Fix wf_withdraw — workflow_tasks has no updated_at column
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- ───────
-- Migration 271 introduced an idempotency guard in wf_withdraw but accidentally
-- changed the workflow_tasks UPDATE from:
--   SET status = 'cancelled', acted_at = now()     ← correct (mig 269)
-- to:
--   SET status = 'cancelled', updated_at = now()   ← wrong  (mig 271)
--
-- workflow_tasks has no 'updated_at' column, only 'acted_at'.
-- This caused: column "updated_at" of relation "workflow_tasks" does not exist
-- when a user clicked "Discard Record" on a rejected hire.
--
-- FIX
-- ───
-- Restore the correct column name (acted_at) while keeping the mig 271
-- idempotency guard intact.
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

  -- ── Idempotency guard (mig 271) ──────────────────────────────────────────
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
  -- FIX (mig 272): use acted_at — workflow_tasks has no updated_at column.
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
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
  'Mig 271: idempotent — already-withdrawn instances are silently ignored. '
  'Mig 272: fix workflow_tasks UPDATE — use acted_at (not updated_at which does not exist).';
