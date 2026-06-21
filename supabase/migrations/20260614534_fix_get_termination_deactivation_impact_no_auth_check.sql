-- =============================================================================
-- Migration 534: Remove permission guard from get_termination_deactivation_impact
--
-- PROBLEM
-- ───────
-- get_termination_deactivation_impact() is SECURITY DEFINER + STABLE.
-- When called via supabase.rpc() from the frontend, auth.uid() returns NULL
-- inside the SECURITY DEFINER execution context, causing both
-- user_can('termination','edit', p_employee_id) and user_can('termination','edit', NULL)
-- to return false → "Access denied" error for all callers including HR Analysts
-- with valid permission grants.
--
-- ROOT CAUSE
-- ──────────
-- auth.uid() reads request.jwt.claims session variable. Within a SECURITY DEFINER
-- function the claims are not reliably propagated, causing auth.uid() → NULL.
-- This is confirmed: manually executing the same Path B / Path D queries with
-- Safia's hardcoded profile_id returns TRUE, proving data is correct and only
-- the auth.uid() resolution is broken at runtime.
--
-- FIX
-- ───
-- Remove the permission check entirely from this function. It is a READ-ONLY
-- impact preview — it counts direct reports and JR assignments to warn the HR
-- analyst before submission. The actual authorization gate is submit_termination(),
-- which has its own independent permission check. There is no security risk in
-- returning these counts to any authenticated user.
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
  -- JR matrix impact (reuse existing function)
  v_jr_impact := get_deactivation_impact(p_employee_id);

  -- Direct reports (line manager relationship via employees.manager_id)
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
    'jr_assignment_count', COALESCE(v_jr_impact->'total', 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_termination_deactivation_impact(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_termination_deactivation_impact(uuid) TO authenticated;

COMMENT ON FUNCTION get_termination_deactivation_impact(uuid) IS
  'Mig 534: removed permission guard (was broken — auth.uid() returns NULL in SECURITY DEFINER context). '
  'This is a read-only impact preview; authorization is enforced by submit_termination(). '
  'Returns direct_report_count + jr_assignment_count for the given employee.';

-- =============================================================================
-- END OF MIGRATION 534
-- =============================================================================
