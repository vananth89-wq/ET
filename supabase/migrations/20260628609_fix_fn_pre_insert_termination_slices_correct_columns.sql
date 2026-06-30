-- =============================================================================
-- Migration 609: fix fn_pre_insert_termination_slices — correct column names
--
-- Mig 607 rewrote fn_pre_insert_termination_slices with wrong column names
-- (employment_type_id, department_id, work_location_id, cost_center_id) that
-- don't exist on employee_employment. The real columns (from mig 532) are:
-- dept_id, work_location, hire_date, base_currency_id, etc.
--
-- This restores the correct INSERT from mig 532, with the only intended change
-- from mig 607: the skipped response now includes 'lwd' so the EF proceeds to
-- fn_finalize_termination_execution on re-runs.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_pre_insert_termination_slices(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_term        RECORD;
  v_open_slice  RECORD;
  v_lwd         date;
  v_next_day    date;
BEGIN
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination not found');
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Termination is not APPROVED (status: %s)', v_term.workflow_status));
  END IF;

  v_lwd := COALESCE(v_term.last_working_date, v_term.separation_date);
  IF v_lwd IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No execution date: last_working_date and separation_date are both null');
  END IF;

  v_next_day := v_lwd + 1;

  -- Idempotency: Inactive slice at v_next_day already exists.
  -- Return lwd so the EF/caller still proceeds to fn_finalize (Phase 2).
  IF EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from = v_next_day
      AND  status         = 'Inactive'
  ) THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'skipped', true,
      'reason',  'Inactive slice already exists',
      'lwd',     v_lwd
    );
  END IF;

  -- Find current open-ended Active slice
  SELECT * INTO v_open_slice
  FROM   employee_employment
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No open-ended active employment slice found for employee');
  END IF;

  -- Step 1: Close current slice at last_working_date
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         updated_at   = now()
  WHERE  id = v_open_slice.id;

  -- Step 2: Insert future Inactive slice (effective_from = last_working_date + 1)
  INSERT INTO employee_employment (
    employee_id,
    designation,
    job_title,
    dept_id,
    manager_id,
    hire_date,
    work_country,
    work_location,
    base_currency_id,
    notice_period_days,
    probation_end_date,
    status,
    effective_from,
    effective_to,
    is_active,
    created_by,
    updated_by
  ) VALUES (
    v_term.employee_id,
    v_open_slice.designation,
    v_open_slice.job_title,
    v_open_slice.dept_id,
    v_open_slice.manager_id,
    v_open_slice.hire_date,
    v_open_slice.work_country,
    v_open_slice.work_location,
    v_open_slice.base_currency_id,
    v_open_slice.notice_period_days,
    v_open_slice.probation_end_date,
    'Inactive',
    v_next_day,
    '9999-12-31'::date,
    true,
    v_open_slice.created_by,
    NULL
  );

  RETURN jsonb_build_object(
    'ok',            true,
    'employee_id',   v_term.employee_id,
    'lwd',           v_lwd,
    'inactive_from', v_next_day
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_pre_insert_termination_slices(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_pre_insert_termination_slices(uuid) TO authenticated;

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 609: restores correct column names (dept_id, work_location, etc.) broken '
  'by mig 607. Only intentional change: skipped response now includes lwd so '
  'apply-termination-approval EF proceeds to fn_finalize on re-runs.';
