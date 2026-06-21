-- =============================================================================
-- Migration 552: update_termination_reassignments RPC
--
-- Allows approvers with termination.reassign.edit permission to save the
-- new-manager assignments for each direct report on a termination record.
-- =============================================================================

CREATE OR REPLACE FUNCTION update_termination_reassignments(
  p_termination_id uuid,
  p_reassignments  jsonb   -- array of {employee_id, employee_name, new_manager_id, new_manager_name}
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_termination_id IS NULL THEN
    RAISE EXCEPTION 'termination_id is required';
  END IF;

  UPDATE employee_terminations
  SET    direct_report_reassignments = COALESCE(p_reassignments, '[]'::jsonb),
         updated_by = auth.uid(),
         updated_at = now()
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination record not found');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$fn$;

COMMENT ON FUNCTION update_termination_reassignments IS
  'Mig 552: saves direct-report manager reassignments for a termination record.';

-- =============================================================================
-- END OF MIGRATION 552
-- =============================================================================
