-- =============================================================================
-- Migration 162: Fix wf_sync_module_status — map 'draft' → 'withdrawn' for
--               profile_* modules on wf_withdraw()
--
-- GAP
-- ───
-- wf_withdraw() always calls:
--   wf_sync_module_status(module_code, record_id, 'draft')
--
-- For expense_reports this is correct — it resets the report to draft status
-- so the submitter can edit and resubmit.
--
-- For profile_* modules, migration 161 added the ELSIF branch which does:
--   UPDATE workflow_pending_changes SET status = p_status ...
--
-- But workflow_pending_changes.status has a CHECK constraint:
--   CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn'))
--
-- 'draft' is not in that list. The UPDATE fails with a constraint violation,
-- leaving the workflow_pending_changes row stuck in 'pending' indefinitely
-- after a withdrawal.
--
-- FIX
-- ───
-- In the profile_* ELSIF branch, map p_status = 'draft' → 'withdrawn'.
-- All other statuses (approved, rejected) pass through unchanged.
--
-- Semantically: a withdrawn profile change request is terminal — the user
-- must submit a new change request to try again. 'withdrawn' is the correct
-- status, matching the workflow_instances terminal state.
--
-- CALLER IMPACT
-- ─────────────
-- No caller changes needed.
--
--   wf_withdraw()         → passes 'draft'    → mapped to 'withdrawn' ✓
--   wf_reject()           → passes 'rejected' → passes through unchanged ✓
--   wf_advance_instance() → passes 'approved' → passes through unchanged ✓
-- =============================================================================


CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
BEGIN
  -- ── Expense reports ────────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles
      WHERE  id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  -- p_record_id = workflow_pending_changes.id
  -- 'draft' (from wf_withdraw) is mapped to 'withdrawn' — 'draft' is not a
  -- valid status for workflow_pending_changes (CHECK constraint).
  -- Updating status fires trg_apply_profile_pending_change (mig 117),
  -- which writes proposed_data to the satellite table on 'approved' only.
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status      = CASE WHEN p_status = 'draft' THEN 'withdrawn' ELSE p_status END,
      resolved_at = now()
    WHERE id = p_record_id;

  -- ── Future modules: add ELSIF branches here ────────────────────────────────
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates status on the source module record after a workflow terminal event. '
  'expense_reports: sets status/approved_at/approved_by. '
  'profile_*: sets status/resolved_at on workflow_pending_changes (draft→withdrawn), '
  'which fires trg_apply_profile_pending_change on approved. '
  'Mig 070: approved_at/approved_by. Mig 161: profile_* branch. Mig 162: draft→withdrawn map.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm function updated
SELECT routine_name, security_type
FROM   information_schema.routines
WHERE  routine_name   = 'wf_sync_module_status'
  AND  routine_schema = 'public';

-- Spot-check: 'draft' is not in the wpc status constraint (should not appear)
SELECT constraint_name, check_clause
FROM   information_schema.check_constraints
WHERE  constraint_name LIKE '%workflow_pending_changes%'
   OR  check_clause    LIKE '%pending%approved%';

-- =============================================================================
-- END OF MIGRATION 162
-- =============================================================================
