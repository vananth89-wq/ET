-- =============================================================================
-- Migration 628: withdraw_termination_reversal RPC
--
-- Allows an admin to withdraw a PENDING reversal (withdraw the workflow
-- instance and set reversal status to WITHDRAWN). This lets the user
-- resubmit a fresh reversal without being blocked by the unique index
-- (which only covers PENDING and APPROVED statuses).
--
-- Guards:
--   • Only PENDING reversals can be withdrawn
--   • Requires termination.edit permission on the employee
--   • Calls wf_withdraw on the workflow instance
--   • Sets reversal workflow_status = WITHDRAWN
-- =============================================================================

CREATE OR REPLACE FUNCTION withdraw_termination_reversal(
  p_reversal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reversal     employee_termination_reversals%ROWTYPE;
  v_termination  employee_terminations%ROWTYPE;
BEGIN

  -- ── 1. Load reversal ───────────────────────────────────────────────────────
  SELECT * INTO v_reversal
  FROM   employee_termination_reversals
  WHERE  id = p_reversal_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reversal record not found.');
  END IF;

  IF v_reversal.workflow_status <> 'PENDING' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Only PENDING reversals can be withdrawn. Current status: '
      || v_reversal.workflow_status || '.');
  END IF;

  -- ── 2. Load parent termination for permission check ────────────────────────
  SELECT * INTO v_termination
  FROM   employee_terminations
  WHERE  id = v_reversal.termination_id;

  -- ── 3. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('termination', 'edit', v_termination.employee_id)
    OR user_can('termination', 'edit', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.edit required.');
  END IF;

  -- ── 4. Withdraw workflow instance ──────────────────────────────────────────
  IF v_reversal.workflow_instance_id IS NOT NULL THEN
    BEGIN
      PERFORM wf_withdraw(v_reversal.workflow_instance_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'withdraw_termination_reversal: wf_withdraw failed for instance % — %',
                    v_reversal.workflow_instance_id, SQLERRM;
    END;
  END IF;

  -- ── 5. Set reversal to WITHDRAWN ───────────────────────────────────────────
  UPDATE employee_termination_reversals
  SET    workflow_status      = 'WITHDRAWN',
         workflow_instance_id = NULL,
         updated_at           = NOW(),
         updated_by           = auth.uid()
  WHERE  id = p_reversal_id;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION withdraw_termination_reversal(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION withdraw_termination_reversal(uuid) TO authenticated;

COMMENT ON FUNCTION withdraw_termination_reversal(uuid) IS
  'Mig 628: withdraws a PENDING reversal — calls wf_withdraw on the instance '
  'and sets workflow_status = WITHDRAWN. The WITHDRAWN status is not covered by '
  'uq_termination_active_reversal so a fresh reversal can be resubmitted.';
