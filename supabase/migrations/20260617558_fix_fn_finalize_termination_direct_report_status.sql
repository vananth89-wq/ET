-- =============================================================================
-- Migration 558: Fix fn_finalize_termination_execution — direct report status
--
-- Bug in mig 536: when creating the new employment slice for each direct report
-- after manager reassignment, it copies v_current_ee.status which can be
-- 'Inactive' (because the terminated employee's status propagates through
-- triggers during the same transaction). Direct reports are still active
-- employees — their new slice must always be 'Active'.
--
-- Fix: hardcode 'Active'::employee_status in the INSERT.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_finalize_termination_execution(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_term          employee_terminations%ROWTYPE;
  v_reassignment  jsonb;
  v_dr_emp_id     uuid;
  v_new_mgr_id    uuid;
  v_current_ee    employee_employment%ROWTYPE;
  v_lwd           date;
  v_eff_from      date;
  v_notice_period_days int;
BEGIN
  -- Load termination record
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Termination record not found: %', p_termination_id;
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RAISE EXCEPTION 'Termination is not APPROVED (status: %)', v_term.workflow_status;
  END IF;

  IF v_term.scheduled_executed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already executed');
  END IF;

  v_lwd      := v_term.last_working_date;
  -- (return value built at end)
  v_eff_from := v_lwd + 1;

  -- Allow employment sync bypass for this transaction
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- ── 1. Deactivate the terminated employee ─────────────────────────────────
  UPDATE employees
  SET    status     = 'Inactive',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  -- Close the terminated employee's open employment slice
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         inactive_by  = auth.uid(),
         updated_by   = auth.uid()
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true;

  -- ── 2. Apply direct report reassignments ──────────────────────────────────
  FOR v_reassignment IN
    SELECT jsonb_array_elements(
      COALESCE(v_term.direct_report_reassignments, '[]'::jsonb)
    )
  LOOP
    v_dr_emp_id  := (v_reassignment->>'employee_id')::uuid;
    v_new_mgr_id := (v_reassignment->>'new_manager_id')::uuid;

    -- Skip if no new manager assigned
    CONTINUE WHEN v_new_mgr_id IS NULL;

    -- Fetch direct report's current open employment slice
    SELECT * INTO v_current_ee
    FROM   employee_employment
    WHERE  employee_id  = v_dr_emp_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
    ORDER  BY effective_from DESC
    LIMIT  1;

    IF NOT FOUND THEN
      CONTINUE; -- no open slice; skip
    END IF;

    -- Close the current slice
    UPDATE employee_employment
    SET    effective_to = v_lwd,
           is_active    = false,
           inactive_at  = now(),
           inactive_by  = auth.uid(),
           updated_by   = auth.uid()
    WHERE  id = v_current_ee.id;

    -- Open new slice from lwd+1 with new manager — status always 'Active'
    INSERT INTO employee_employment (
      employee_id,
      designation,
      job_title,
      dept_id,
      manager_id,
      hire_date,
      end_date,
      work_country,
      work_location,
      base_currency_id,
      notice_period_days,
      status,
      effective_from,
      effective_to,
      is_active,
      created_by,
      updated_by
    ) VALUES (
      v_dr_emp_id,
      v_current_ee.designation,
      v_current_ee.job_title,
      v_current_ee.dept_id,
      v_new_mgr_id,
      v_current_ee.hire_date,
      v_current_ee.end_date,
      v_current_ee.work_country,
      v_current_ee.work_location,
      v_current_ee.base_currency_id,
      v_current_ee.notice_period_days,
      'Active'::employee_status,   -- ← fixed: direct reports remain Active
      v_eff_from,
      '9999-12-31'::date,
      true,
      auth.uid(),
      auth.uid()
    );

    -- Update the mirror on employees
    UPDATE employees
    SET    manager_id = v_new_mgr_id,
           updated_at = now()
    WHERE  id = v_dr_emp_id;

  END LOOP;

  -- ── 3. Stamp execution ────────────────────────────────────────────────────
  UPDATE employee_terminations
  SET    scheduled_executed    = true,
         scheduled_executed_at = now(),
         updated_by            = auth.uid()
  WHERE  id = p_termination_id;

  RETURN jsonb_build_object('ok', true);

END;
$fn$;

COMMENT ON FUNCTION fn_finalize_termination_execution(uuid) IS
  'Mig 558: fixes direct-report new employment slice to use status=Active (not copied from old slice).';

-- =============================================================================
-- END OF MIGRATION 558
-- =============================================================================

REVOKE ALL     ON FUNCTION fn_finalize_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_finalize_termination_execution(uuid) TO authenticated;
