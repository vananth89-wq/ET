-- Migration 565 — get_hire_clarification_instance RPC
-- ──────────────────────────────────────────────────────
-- The AddEmployee frontend detects whether to call wf_resubmit (sent-back path)
-- or submit_hire (fresh submission) by querying workflow_instances directly.
-- But the RLS SELECT policy only allows submitted_by = auth.uid(), so a different
-- HR user resuming the same record gets null back and incorrectly calls submit_hire.
-- Fix: SECURITY DEFINER function that bypasses RLS for this specific lookup.
-- Returns the awaiting_clarification instance id for a given employee hire record,
-- or NULL if none exists. Callers with hire_employee.edit OR an active pending
-- workflow task on this record may call this.

CREATE OR REPLACE FUNCTION get_hire_clarification_instance(p_employee_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance_id uuid;
BEGIN
  -- Access guard: must be able to edit hire records OR have an active task
  IF NOT (
    user_can('hire_employee', 'edit', NULL)
    OR user_can('hire_employee', 'edit_all_pending', NULL)
    OR is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wi.module_code = 'employee_hire'
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_instance_id
  FROM   workflow_instances
  WHERE  module_code = 'employee_hire'
    AND  record_id   = p_employee_id
    AND  status      = 'awaiting_clarification'
  LIMIT  1;

  RETURN v_instance_id;
END;
$$;

REVOKE ALL     ON FUNCTION get_hire_clarification_instance(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_hire_clarification_instance(uuid) TO authenticated;

COMMENT ON FUNCTION get_hire_clarification_instance(uuid) IS
  'Returns the awaiting_clarification workflow_instances.id for an employee_hire '
  'record, or NULL if none exists. SECURITY DEFINER bypasses RLS so any authorised '
  'HR user (not just the original submitter) can detect the sent-back path and '
  'route to wf_resubmit instead of submit_hire. Mig 565.';
