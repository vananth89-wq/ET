-- =============================================================================
-- Migration 832: Allow deleting the active JR set
--
-- Job relationships are fully optional — an employee may have zero sets.
-- Remove the guard that blocked deletion of the active set, and add mirror-
-- column nullification when the active set is deleted.
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_delete_job_relationship_set(
  p_set_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
  v_is_active   boolean;
BEGIN
  -- Permission gate
  IF NOT user_can('job_relationships', 'delete', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied');
  END IF;

  SELECT employee_id, is_active
  INTO   v_employee_id, v_is_active
  FROM   employee_job_relationship_set
  WHERE  id = p_set_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Set not found');
  END IF;

  -- If deleting the active set, null out mirror columns first
  IF v_is_active THEN
    PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);
    UPDATE employees SET
      pm01_manager_id = NULL,
      pm02_manager_id = NULL,
      pm03_manager_id = NULL,
      om01_manager_id = NULL,
      om02_manager_id = NULL,
      om03_manager_id = NULL
    WHERE id = v_employee_id;
    PERFORM set_config('prowess.allow_job_relationships_sync', 'false', true);
  END IF;

  DELETE FROM employee_job_relationship_item WHERE set_id = p_set_id;
  DELETE FROM employee_job_relationship_set   WHERE id    = p_set_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_job_relationship_set(uuid) TO authenticated;
