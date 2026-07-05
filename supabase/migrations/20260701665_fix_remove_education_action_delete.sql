-- Migration 665 — Fix remove_education: use 'delete' not 'remove' for p_action
-- workflow_pending_changes_action_check only allows 'create', 'update', 'delete'.

CREATE OR REPLACE FUNCTION remove_education(
  p_employee_id  uuid,
  p_education_id uuid,
  p_force_path_a boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor             uuid := auth.uid();
  v_is_hire           boolean;
  v_has_wf_assignment boolean;
  v_is_path_a         boolean;
  v_submit_result     jsonb;
BEGIN
  IF NOT (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'edit',   NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM employee_education
    WHERE id = p_education_id AND employee_id = p_employee_id AND is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already deleted.');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);
  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => jsonb_build_object('_operation', 'remove', 'education_id', p_education_id),
      p_action              => 'delete',   -- constraint allows: create / update / delete
      p_subject_employee_id => p_employee_id
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- Path A: direct soft-delete
  UPDATE employee_education
  SET is_active = false, updated_by = v_actor, updated_at = NOW()
  WHERE id = p_education_id AND employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'workflow', false);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION remove_education(uuid, uuid, boolean) TO authenticated;
