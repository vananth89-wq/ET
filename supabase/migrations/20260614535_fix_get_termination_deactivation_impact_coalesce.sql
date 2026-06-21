-- =============================================================================
-- Migration 535: Fix type mismatch in get_termination_deactivation_impact
--
-- COALESCE(v_jr_impact->'total', 0) fails because -> returns jsonb but 0 is
-- integer. Cast the fallback to jsonb.
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
  v_jr_impact       jsonb;
  v_direct_reports  jsonb;
  v_direct_count    int;
BEGIN
  v_jr_impact := get_deactivation_impact(p_employee_id);

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
    'ok',                  true,
    'direct_reports',      v_direct_reports,
    'direct_report_count', v_direct_count,
    'jr_assignments',      COALESCE(v_jr_impact->'affected_employees', '[]'::jsonb),
    'jr_assignment_count', COALESCE(v_jr_impact->'total', '0'::jsonb)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_deactivation_impact(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_deactivation_impact(uuid) TO authenticated;
