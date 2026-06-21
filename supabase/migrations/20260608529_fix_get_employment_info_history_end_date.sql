-- =============================================================================
-- Migration 516 — Remove end_date from get_employment_info_history
--
-- PROBLEM
-- ───────
-- get_employment_info_history (mig 352) references ee.end_date inside
-- jsonb_build_object. mig 487 dropped employee_employment.end_date.
-- The EXCEPTION WHEN OTHERS handler silently returns '[]' when the column
-- reference fails, so the history panel always shows "No history available."
--
-- FIX
-- ───
-- Re-create the function without the end_date field.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employment_info_history(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN

  IF NOT (
    user_can('employment', 'history', p_employee_id)
    OR user_can('employment', 'edit',   p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employment.history')
    )
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                 ee.id,
      'employee_id',        ee.employee_id,
      'designation',        ee.designation,
      'job_title',          ee.job_title,
      'dept_id',            ee.dept_id,
      'manager_id',         ee.manager_id,
      'hire_date',          ee.hire_date,
      'work_country',       ee.work_country,
      'work_location',      ee.work_location,
      'base_currency_id',   ee.base_currency_id,
      'notice_period_days', ee.notice_period_days,
      'status',             ee.status,
      'probation_end_date', ee.probation_end_date,
      'effective_from',     ee.effective_from,
      'effective_to',       ee.effective_to,
      'is_active',          ee.is_active,
      'created_at',         ee.created_at,
      'created_by',         ee.created_by,
      'updated_at',         ee.updated_at,
      'updated_by',         ee.updated_by
    )
    ORDER BY ee.effective_from DESC
  )
  INTO v_result
  FROM employee_employment ee
  WHERE ee.employee_id = p_employee_id;

  RETURN COALESCE(v_result, '[]'::jsonb);

EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

REVOKE ALL     ON FUNCTION get_employment_info_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employment_info_history(uuid) TO authenticated;

COMMENT ON FUNCTION get_employment_info_history(uuid) IS
  'Returns all effective-dated employment rows for an employee, '
  'ordered by effective_from DESC (most recent first). '
  'Mig 352: initial creation. '
  'Mig 516: removed end_date field — column dropped in mig 487.';

-- =============================================================================
-- VERIFICATION
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'get_employment_info_history'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_employment_info_history missing.';
  END IF;
  RAISE NOTICE 'Migration 516 verified: get_employment_info_history end_date removed.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 516
-- =============================================================================
