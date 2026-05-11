-- =============================================================================
-- Migration 183: Fix "column reference module_code is ambiguous" in wf_prepare_update
--
-- PostgreSQL error 42702: the RETURNS TABLE(...) declaration names output
-- columns `module_code` and `record_id`, which clashes with the unqualified
-- column names in the SELECT INTO query that loads from workflow_instances.
-- PostgreSQL cannot tell whether the bare name refers to the table column or
-- the output column.
--
-- Fix: add a table alias `wi` to the SELECT INTO query so every column
-- reference is unambiguously qualified (wi.module_code, wi.record_id, etc.).
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
  -- that share the names module_code and record_id.
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

  -- ── Unlock module record for editing ──────────────────────────────────────
  PERFORM wf_sync_module_status(
    v_instance.module_code,
    v_instance.record_id,
    'needs_update'
  );

  -- ── Audit log ──────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id,
    auth.uid(),
    'update_started',
    v_instance.current_step,
    'Submitter opened request for editing after clarification'
  );

  -- ── Return routing info to frontend ───────────────────────────────────────
  RETURN QUERY
    SELECT v_instance.module_code::text, v_instance.record_id;
END;
$$;

COMMENT ON FUNCTION wf_prepare_update(uuid) IS
  'Unlocks a sent-back module record for employee editing. '
  'Sets module status to needs_update (preventing normal new-instance Submit). '
  'Returns module_code and record_id so the frontend can navigate to the '
  'correct edit form with ?resume_instance={instanceId}. '
  'Only valid when instance is awaiting_clarification. '
  'Mig 183: table alias fix for column reference ambiguity (42702).';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname, prosrc LIKE '%FROM workflow_instances wi%' AS uses_alias
FROM   pg_proc
WHERE  proname = 'wf_prepare_update';

-- =============================================================================
-- END OF MIGRATION 183
-- =============================================================================
