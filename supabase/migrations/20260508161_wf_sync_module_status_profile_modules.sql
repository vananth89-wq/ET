-- =============================================================================
-- Migration 161: Wire profile_* modules into wf_sync_module_status()
--
-- GAP
-- ───
-- wf_sync_module_status() is called by wf_advance_instance() when all
-- approval steps are complete. It updates the source record's status so the
-- module knows the workflow resolved.
--
-- Before this migration it only handled 'expense_reports'. Every other module
-- fell into the ELSE branch which emits a NOTICE and does nothing:
--
--   RAISE NOTICE 'wf_sync_module_status: unknown module_code %, record unchanged'
--
-- This meant workflow_pending_changes rows for profile_* modules were never
-- updated from 'pending' → 'approved' / 'rejected', and the AFTER UPDATE
-- trigger trg_apply_profile_pending_change (migration 117) that applies
-- proposed_data to satellite tables never fired.
--
-- FIX
-- ───
-- Add an ELSIF branch for module_code LIKE 'profile_%':
--
--   UPDATE workflow_pending_changes
--     SET  status      = p_status,
--          resolved_at = now()
--   WHERE  id = p_record_id;
--
-- When status transitions to 'approved', trg_apply_profile_pending_change
-- fires automatically and writes proposed_data to the correct satellite table:
--
--   profile_personal          → employee_personal   (upsert)
--   profile_contact           → employee_contact    (upsert)
--   profile_address           → employee_addresses  (insert or update)
--   profile_passport          → passports           (insert or update)
--   profile_emergency_contact → emergency_contacts  (insert or update)
--
-- When status = 'rejected' the trigger is a no-op (fires but returns early).
--
-- FULL APPROVAL CHAIN (after this migration)
-- ──────────────────────────────────────────
--   wf_approve()
--     → wf_advance_instance()                       last step only
--       → wf_sync_module_status('profile_*', wpc.id, 'approved')
--         → UPDATE workflow_pending_changes          ← this migration
--           → trg_apply_profile_pending_change       ← mig 117, fires on UPDATE
--             → upsert/update satellite table        ← data lands ✓
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
  -- Updating status here fires trg_apply_profile_pending_change (mig 117)
  -- which writes proposed_data to the correct satellite table.
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status      = p_status,
      resolved_at = now()
    WHERE id = p_record_id;

  -- ── Future modules: add ELSIF branches here ────────────────────────────────
  -- ELSIF p_module_code = 'leave_requests' THEN
  --   UPDATE leave_requests SET status = p_status, updated_at = now()
  --   WHERE id = p_record_id;

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
  'profile_*: sets status/resolved_at on workflow_pending_changes, which fires '
  'trg_apply_profile_pending_change to write proposed_data to satellite tables. '
  'Mig 070: added approved_at/approved_by. Mig 161: added profile_* modules.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm function updated
SELECT routine_name, security_type
FROM   information_schema.routines
WHERE  routine_name   = 'wf_sync_module_status'
  AND  routine_schema = 'public';

-- Confirm trigger still attached (mig 117)
SELECT trigger_name, event_manipulation, action_timing
FROM   information_schema.triggers
WHERE  trigger_name        = 'trg_apply_profile_pending_change'
  AND  event_object_table  = 'workflow_pending_changes';

-- =============================================================================
-- END OF MIGRATION 161
-- =============================================================================
