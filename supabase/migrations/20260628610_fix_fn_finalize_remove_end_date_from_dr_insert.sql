-- =============================================================================
-- Migration 610: fn_finalize_termination_execution — remove end_date from DR INSERT
--
-- Bug: mig 596's DR reassignment INSERT included end_date, which was dropped
-- from employee_employment in mig 487. The per-DR exception handler caught
-- the error silently → all DRs failed → scheduled_executed was stamped true
-- → Re-run button hidden → DR manager reassignment permanently skipped.
--
-- Fix: remove end_date from the INSERT column list and VALUES clause.
-- Also reset scheduled_executed = false for terminations that are APPROVED,
-- Inactive, and have DRs still pointing to the terminated employee, so the
-- Re-run Finalization button reappears for affected records.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_finalize_termination_execution(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
DECLARE
  v_term              employee_terminations%ROWTYPE;
  v_reassignment      jsonb;
  v_dr_emp_id         uuid;
  v_dr_name           text;
  v_new_mgr_id        uuid;
  v_covering_ee       employee_employment%ROWTYPE;
  v_first_future_from date;
  v_new_slice_to      date;
  v_lwd               date;
  v_eff_from          date;
  v_dr_errors         jsonb := '[]'::jsonb;
BEGIN

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
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already executed');
  END IF;

  v_lwd      := v_term.last_working_date;
  v_eff_from := v_lwd + 1;

  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- ── STEP 1: Deactivate terminated employee ────────────────────────────────

  UPDATE employees
  SET    status     = 'Inactive',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  -- Close only the slice active ON the LWD.
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         inactive_by  = auth.uid(),
         updated_by   = auth.uid()
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from <= v_lwd
    AND  effective_to   = '9999-12-31'::date
    AND  is_active      = true;

  -- Delete spurious future records that start after the inactive marker (LWD+1).
  DELETE FROM employee_employment
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from > v_eff_from
    AND  is_active      = true;

  -- ── STEP 2: Apply direct report reassignments ─────────────────────────────

  FOR v_reassignment IN
    SELECT jsonb_array_elements(
      COALESCE(v_term.direct_report_reassignments, '[]'::jsonb)
    )
  LOOP
    v_dr_emp_id  := (v_reassignment->>'employee_id')::uuid;
    v_dr_name    := COALESCE(v_reassignment->>'employee_name', v_dr_emp_id::text);
    v_new_mgr_id := (v_reassignment->>'new_manager_id')::uuid;

    CONTINUE WHEN v_new_mgr_id IS NULL;

    BEGIN

      -- Find the employment slice covering the LWD for this DR.
      -- No is_active filter — the covering slice may already be closed
      -- if the DR had a newer employment slice starting after the LWD.
      SELECT * INTO v_covering_ee
      FROM   employee_employment
      WHERE  employee_id    = v_dr_emp_id
        AND  effective_from <= v_lwd
        AND  effective_to   >= v_lwd
      ORDER  BY effective_from DESC
      LIMIT  1;

      IF NOT FOUND THEN
        -- No slice covers the LWD — DR may have already left. Skip.
        NULL;
      ELSE

        -- Find the first future slice (starts after LWD).
        SELECT effective_from INTO v_first_future_from
        FROM   employee_employment
        WHERE  employee_id    = v_dr_emp_id
          AND  effective_from > v_lwd
        ORDER  BY effective_from ASC
        LIMIT  1;

        IF v_first_future_from IS NOT NULL THEN
          v_new_slice_to := v_first_future_from - 1;
        ELSE
          v_new_slice_to := '9999-12-31'::date;
        END IF;

        -- Close the covering slice at LWD (only if still open-ended)
        UPDATE employee_employment
        SET    effective_to = v_lwd,
               is_active    = false,
               inactive_at  = now(),
               inactive_by  = auth.uid(),
               updated_by   = auth.uid()
        WHERE  id            = v_covering_ee.id
          AND  effective_to  = '9999-12-31'::date;

        -- Insert in-between slice: LWD+1 to (first_future - 1) or 9999-12-31
        -- Only insert if it won't overlap an existing slice.
        IF NOT EXISTS (
          SELECT 1 FROM employee_employment
          WHERE  employee_id    = v_dr_emp_id
            AND  effective_from = v_eff_from
        ) THEN
          INSERT INTO employee_employment (
            employee_id, designation, job_title, dept_id, manager_id,
            hire_date, work_country, work_location,
            base_currency_id, notice_period_days, probation_end_date,
            status, effective_from, effective_to, is_active,
            created_by, updated_by
          ) VALUES (
            v_dr_emp_id,
            v_covering_ee.designation,      v_covering_ee.job_title,
            v_covering_ee.dept_id,          v_new_mgr_id,
            v_covering_ee.hire_date,
            v_covering_ee.work_country,     v_covering_ee.work_location,
            v_covering_ee.base_currency_id, v_covering_ee.notice_period_days,
            v_covering_ee.probation_end_date,
            'Active'::employee_status,
            v_eff_from, v_new_slice_to, true,
            auth.uid(), auth.uid()
          );
        END IF;

        -- Propagate new manager to ALL existing future slices
        UPDATE employee_employment
        SET    manager_id = v_new_mgr_id,
               updated_by = auth.uid()
        WHERE  employee_id    = v_dr_emp_id
          AND  effective_from > v_lwd;

        -- Keep employees.manager_id mirror in sync
        UPDATE employees
        SET    manager_id = v_new_mgr_id,
               updated_at = now()
        WHERE  id = v_dr_emp_id;

      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_dr_errors := v_dr_errors || jsonb_build_object(
        'employee_id',   v_dr_emp_id,
        'employee_name', v_dr_name,
        'error',         SQLERRM
      );
    END;

  END LOOP;

  -- ── STEP 3: Stamp execution ───────────────────────────────────────────────
  UPDATE employee_terminations
  SET    scheduled_executed    = true,
         scheduled_executed_at = now(),
         updated_by            = auth.uid()
  WHERE  id = p_termination_id;

  IF jsonb_array_length(v_dr_errors) > 0 THEN
    RETURN jsonb_build_object(
      'ok',        false,
      'error',     'Reassignment failed for ' || jsonb_array_length(v_dr_errors) || ' direct report(s)',
      'dr_errors', v_dr_errors
    );
  END IF;

  RETURN jsonb_build_object('ok', true);

END;
$body$;

COMMENT ON FUNCTION fn_finalize_termination_execution(uuid) IS
  'Mig 610: removes end_date from DR INSERT — column was dropped by mig 487 '
  'but mig 596 kept it, causing a silent per-DR exception that skipped all '
  'reassignments while stamping scheduled_executed=true.';

REVOKE ALL     ON FUNCTION fn_finalize_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_finalize_termination_execution(uuid) TO authenticated;

-- ── Reset scheduled_executed so Re-run button reappears ──────────────────────
-- Targets: APPROVED terminations where employee is Inactive but a DR still
-- points to them as manager (DR reassignment was silently skipped).
UPDATE employee_terminations et
SET    scheduled_executed    = false,
       scheduled_executed_at = NULL
WHERE  et.workflow_status    = 'APPROVED'
  AND  et.scheduled_executed = true
  AND  EXISTS (
         SELECT 1 FROM employees term_emp
         WHERE  term_emp.id     = et.employee_id
           AND  term_emp.status = 'Inactive'
       )
  AND  EXISTS (
         SELECT 1 FROM employees dr
         WHERE  dr.manager_id = et.employee_id
       );
