-- =============================================================================
-- Migration 617: get_termination_deactivation_impact — add terminating manager
--
-- Adds terminating_manager_id and terminating_manager_name to the response so
-- the Impact modal can pre-populate each DR's reassignment with the terminated
-- employee's manager as a default fallback.
--
-- Behaviour change: if no reassignment is selected for a DR in the modal, the
-- frontend uses terminating_manager_id as the fallback — meaning DRs
-- automatically roll up to their manager's manager on termination.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_termination_deactivation_impact(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jr_impact              jsonb;
  v_direct_reports         jsonb;
  v_direct_count           int;
  v_terminating_manager_id uuid;
  v_terminating_manager_nm text;
  v_terminating_mgr_code   text;
BEGIN
  v_jr_impact := get_deactivation_impact(p_employee_id);

  -- Fetch the terminated employee's current manager
  SELECT e.manager_id, mgr.name, mgr.employee_id
  INTO   v_terminating_manager_id, v_terminating_manager_nm, v_terminating_mgr_code
  FROM   employees e
  LEFT JOIN employees mgr ON mgr.id = e.manager_id
  WHERE  e.id = p_employee_id;

  SELECT
    COUNT(*)::int,
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'employee_id',   e.id,
        'employee_code', e.employee_id,
        'name',          e.name
      ) ORDER BY e.name
    ), '[]'::jsonb)
  INTO v_direct_count, v_direct_reports
  FROM employees e
  WHERE e.manager_id = p_employee_id
    AND e.status     = 'Active'
    AND e.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'ok',                       true,
    'direct_reports',           v_direct_reports,
    'direct_report_count',      v_direct_count,
    'jr_assignments',           COALESCE(v_jr_impact->'affected_employees', '[]'::jsonb),
    'jr_assignment_count',      COALESCE(v_jr_impact->'total', '0'::jsonb),
    'terminating_manager_id',   v_terminating_manager_id,
    'terminating_manager_name', v_terminating_manager_nm,
    'terminating_manager_code', v_terminating_mgr_code
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_deactivation_impact(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_deactivation_impact(uuid) TO authenticated;

COMMENT ON FUNCTION get_termination_deactivation_impact(uuid) IS
  'Mig 617: adds terminating_manager_id/name/code so the Impact modal can '
  'pre-populate DR reassignments with the manager''s manager as default fallback.';
