-- =============================================================================
-- Migration 184: Make wf_prepare_update module-agnostic
--
-- Previously wf_prepare_update called:
--   PERFORM wf_sync_module_status(module_code, record_id, 'needs_update');
--
-- This required wf_sync_module_status to have an explicit branch for every
-- module that supports the sent-back / update flow. That doesn't scale.
--
-- New approach: wf_prepare_update simply records the audit event and returns
-- routing info. The frontend's *existing* resume-mode guard in MyProfile
-- (and any other form) uses get_my_workflow_instance to check that the
-- instance is still in awaiting_clarification status — so no module-level
-- status flip is needed to gate re-entry.
--
-- This migration MUST be deployed together with the MyProfile frontend change
-- that replaces the wpcRow.status === 'needs_update' guard with a
-- get_my_workflow_instance / awaiting_clarification check.
--
-- NOTE: The audit action label is also corrected from 'update_started' to
-- 'update_form_opened' — the function only opens the form, it doesn't start
-- a DB write. The old label was misleading.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_prepare_update(
  p_instance_id uuid
) RETURNS TABLE(module_code text, record_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  -- ── Load and lock instance ─────────────────────────────────────────────────
  -- Table alias `wi` avoids ambiguity with the RETURNS TABLE output columns
  -- that share the names module_code and record_id (PostgreSQL 42702).
  SELECT wi.id, wi.submitted_by, wi.status, wi.module_code, wi.record_id, wi.current_step
  INTO   v_instance
  FROM   workflow_instances wi
  WHERE  wi.id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_prepare_update: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION
      'wf_prepare_update: instance is not awaiting clarification (status: %)',
      v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_prepare_update: only the submitter or an admin can initiate an update';
  END IF;

  -- ── No module-status flip (mig 184) ───────────────────────────────────────
  -- Previously called wf_sync_module_status(module_code, record_id, 'needs_update')
  -- here. That required a branch per module. The frontend now uses
  -- get_my_workflow_instance to verify awaiting_clarification status instead,
  -- making this function fully module-agnostic.

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id,
    auth.uid(),
    'update_form_opened',
    v_instance.current_step,
    'Submitter opened request for editing after clarification'
  );

  -- ── Return routing info to frontend ───────────────────────────────────────
  RETURN QUERY
    SELECT v_instance.module_code::text, v_instance.record_id;
END;
$$;

COMMENT ON FUNCTION wf_prepare_update(uuid) IS
  'Opens the update form for a sent-back workflow instance. '
  'Validates that the instance is awaiting_clarification and the caller is '
  'the original submitter (or admin). Returns module_code + record_id so the '
  'frontend can navigate to the correct edit form with ?resume_instance=. '
  'Does NOT flip module status (mig 184): the frontend guard uses '
  'get_my_workflow_instance to check awaiting_clarification directly. '
  'Table alias fix for PostgreSQL 42702 column ambiguity (mig 183). '
  'Audit action: update_form_opened (renamed from update_started in mig 184).';


-- ════════════════════════════════════════════════════════════════════════════
-- Update WorkflowTimeline / WorkflowOperations action config
-- ════════════════════════════════════════════════════════════════════════════
-- The frontend ACTION_CONFIG maps include 'update_started' — that label is
-- now replaced by 'update_form_opened'. Both old and new logs may coexist in
-- the DB, so both keys should be handled in the frontend. No SQL change needed
-- here — this is a documentation reminder for the frontend developer.
--
-- Frontend files to update:
--   src/workflow/components/WorkflowTimeline.tsx  → ACTION_CONFIG
--   src/workflow/screens/WorkflowOperations.tsx   → ACTION_CONFIG / statusConfig
-- ════════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname,
       prosrc NOT LIKE '%wf_sync_module_status%needs_update%' AS no_needs_update_flip,
       prosrc LIKE '%update_form_opened%'                      AS uses_new_action_label
FROM   pg_proc
WHERE  proname = 'wf_prepare_update';

-- =============================================================================
-- END OF MIGRATION 184
-- =============================================================================
