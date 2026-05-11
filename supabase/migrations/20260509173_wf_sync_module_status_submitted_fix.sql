-- =============================================================================
-- Migration 173: Fix wf_sync_module_status — map 'submitted'/'in_progress'
--               → 'pending' for profile_* modules
--
-- ROOT CAUSE
-- ──────────
-- wf_submit() (migration 121) always calls:
--
--   PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
--
-- For profile_* modules, migration 162 added the ELSIF branch which does:
--
--   UPDATE workflow_pending_changes
--     SET status = CASE WHEN p_status = 'draft' THEN 'withdrawn' ELSE p_status END
--   WHERE id = p_record_id;
--
-- Because 'submitted' is not 'draft', it falls through to ELSE and tries to
-- SET status = 'submitted'. But workflow_pending_changes.status has a CHECK
-- constraint:
--
--   CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn'))
--
-- 'submitted' is not in that list, so the UPDATE fails with:
--   "new row for relation "workflow_pending_changes" violates check constraint
--    "workflow_pending_changes_status_check""
--
-- This breaks every profile_* workflow submission.
--
-- FIX
-- ───
-- Map all "workflow in progress" statuses that are not terminal to 'pending'
-- (meaning: still awaiting approval). Complete status mapping for profile_*:
--
--   'submitted'   → 'pending'   (wf just started — still awaiting approval)
--   'in_progress' → 'pending'   (wf advancing — still awaiting approval)
--   'draft'       → 'withdrawn' (wf_withdraw — user pulled it back)
--   'approved'    → 'approved'  (all steps approved ✓)
--   'rejected'    → 'rejected'  (a step rejected ✓)
--   'withdrawn'   → 'withdrawn' (pass-through)
--   'cancelled'   → 'withdrawn' (admin cancel)
--   anything else → no-op (leave status unchanged via ELSE status)
--
-- CALLER IMPACT
-- ─────────────
-- No caller changes needed.
--
--   wf_submit()           → 'submitted'   → mapped to 'pending'   ✓  (was broken)
--   wf_advance_instance() → 'approved'    → 'approved'            ✓
--   wf_advance_instance() → 'in_progress' → 'pending'             ✓
--   wf_reject()           → 'rejected'    → 'rejected'            ✓
--   wf_withdraw()         → 'draft'       → 'withdrawn'           ✓
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
  --
  -- Map all workflow-engine statuses to the valid CHECK values for wpc.status:
  --   ('pending', 'approved', 'rejected', 'withdrawn')
  --
  -- 'submitted' and 'in_progress' both mean the change is still awaiting a
  -- decision, so they map to 'pending'.
  -- 'draft' is the status passed by wf_withdraw() — maps to 'withdrawn'.
  -- 'cancelled' (admin cancel) also maps to 'withdrawn'.
  -- Terminal statuses 'approved'/'rejected' pass through unchanged.
  -- Unknown statuses are a no-op (status column left as-is) to avoid
  -- accidental data corruption from future engine additions.
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'   THEN 'pending'
          WHEN 'in_progress' THEN 'pending'
          WHEN 'draft'       THEN 'withdrawn'
          WHEN 'cancelled'   THEN 'withdrawn'
          WHEN 'approved'    THEN 'approved'
          WHEN 'rejected'    THEN 'rejected'
          WHEN 'withdrawn'   THEN 'withdrawn'
          ELSE status   -- no-op for unknown statuses
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
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
  'Updates status on the source module record after a workflow event. '
  'expense_reports: sets status/approved_at/approved_by. '
  'profile_*: maps workflow engine statuses to wpc CHECK-constraint values '
  '(submitted/in_progress→pending, draft/cancelled→withdrawn, approved/rejected pass-through). '
  'Mig 070: approved_at/approved_by. Mig 161: profile_* branch. '
  'Mig 162: draft→withdrawn. Mig 173: submitted/in_progress→pending fix.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm function updated
SELECT routine_name, security_type
FROM   information_schema.routines
WHERE  routine_name   = 'wf_sync_module_status'
  AND  routine_schema = 'public';

-- Spot-check: 'submitted' must not reach the CHECK constraint for wpc.status
-- After applying, run a test profile_personal submission — it should succeed.
-- SELECT get_workflow_participants('profile_personal');

-- =============================================================================
-- END OF MIGRATION 173
--
-- After applying: no type regen needed (no schema or function signature change).
-- =============================================================================
