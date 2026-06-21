-- =============================================================================
-- Migration 463 — wf_activate_employee: mirror job relationships on activation
--
-- PROBLEM
-- ───────
-- Mig 458 added an employment mirror step to wf_activate_employee so that
-- designation/dept_id/hire_date etc. are immediately correct when a hire is
-- approved. But it did not mirror job relationship columns (pm01–om03_manager_id).
--
-- A newly activated employee has NULL pm01–om03 in the employees base table
-- until the nightly cron runs at 00:05 — even if the hire wizard collected
-- job relationship data. This causes gaps in the org chart and any query
-- reading job relationship mirrors directly from employees.
--
-- FIX
-- ───
-- After step 4 (employment mirror), add step 4b: look up the current open-ended
-- job-relationship set for this employee. If one exists and its effective_from
-- is <= today, call sync_job_relationship_mirrors to mirror immediately.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_employee_id   text;
  v_created_by    uuid;
  v_hire_date     date;
  v_next_attempt  int;
  v_has_instance  boolean;
  v_notify_target uuid;
  v_first_name    text;
  v_last_name     text;
  v_computed_name text;
  -- Employment satellite
  v_emp_sat       employee_employment%ROWTYPE;
  -- Job relationship satellite
  v_jr_set_id     uuid;
  v_jr_eff_from   date;
BEGIN
  SELECT status::text, business_email, name, employee_id, created_by, hire_date
  INTO   v_status, v_email, v_name, v_employee_id, v_created_by, v_hire_date
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'wf_activate_employee: employee % is already Active — cannot re-activate.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Step 1: Flip employees.status → Active ─────────────────────────────────
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 2: Seed employee_personal if missing ─────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    v_first_name := CASE
      WHEN position(' ' IN v_name) > 0
        THEN left(v_name, length(v_name) - length(split_part(v_name, ' ', -1)) - 1)
      ELSE COALESCE(v_name, 'Unknown')
    END;
    v_last_name := CASE
      WHEN position(' ' IN v_name) > 0
        THEN split_part(v_name, ' ', -1)
      ELSE NULL
    END;
    v_computed_name := compute_full_name(v_first_name, NULL, v_last_name);

    INSERT INTO employee_personal (
      employee_id, name, first_name, last_name,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_computed_name, v_first_name, v_last_name,
      COALESCE(v_hire_date, CURRENT_DATE), '9999-12-31'::date,
      true, auth.uid(), auth.uid()
    );
  END IF;

  -- ── Step 3: Handle employee_employment satellite ───────────────────────────
  SELECT * INTO v_emp_sat
  FROM   employee_employment
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true;

  IF FOUND THEN
    UPDATE employee_employment
    SET    status     = 'Active',
           updated_at = NOW()
    WHERE  id = v_emp_sat.id
      AND  status != 'Active';

    -- ── Step 4: Mirror employment satellite → employees base ────────────────
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);
    UPDATE employees SET
      designation      = v_emp_sat.designation,
      job_title        = v_emp_sat.job_title,
      dept_id          = v_emp_sat.dept_id,
      manager_id       = v_emp_sat.manager_id,
      hire_date        = v_emp_sat.hire_date,
      end_date         = v_emp_sat.end_date,
      work_country     = v_emp_sat.work_country,
      work_location    = v_emp_sat.work_location,
      base_currency_id = v_emp_sat.base_currency_id
    WHERE id = p_employee_id;

  ELSE
    -- Fallback: no satellite row — seed from employees base
    DECLARE v_emp employees%ROWTYPE; BEGIN
      SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
      INSERT INTO employee_employment (
        employee_id, designation, job_title, dept_id, manager_id,
        hire_date, end_date, work_country, work_location, base_currency_id,
        status, effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_emp.designation, v_emp.job_title, v_emp.dept_id,
        v_emp.manager_id, v_emp.hire_date, v_emp.end_date, v_emp.work_country,
        v_emp.work_location, v_emp.base_currency_id, 'Active',
        COALESCE(v_emp.hire_date, CURRENT_DATE), '9999-12-31'::date,
        true, auth.uid(), auth.uid()
      ) ON CONFLICT DO NOTHING;
    END;
  END IF;

  -- ── Step 4b: Mirror job relationship satellite → employees base (mig 463) ──
  -- Same rationale as step 4 for employment: without this, pm01–om03_manager_id
  -- columns are NULL until the nightly cron, even when the hire wizard collected
  -- job relationship data. Mirror immediately on activation for consistency.
  SELECT id, effective_from
  INTO   v_jr_set_id, v_jr_eff_from
  FROM   employee_job_relationship_set
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT 1;

  IF FOUND AND v_jr_eff_from <= CURRENT_DATE THEN
    PERFORM sync_job_relationship_mirrors(p_employee_id, v_jr_set_id);
  END IF;

  -- ── Step 5: Record invite ──────────────────────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 6: Workflow / notification guard ──────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
      RAISE EXCEPTION
        'A workflow approval process is configured for New Hire. '
        'Please use "Submit for Approval" instead of activating directly. '
        'Direct activation is only available when no workflow is configured.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_notify_target := COALESCE(v_created_by, auth.uid());

    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_notify_target,
      'Employee activated: ' || COALESCE(v_computed_name, v_name),
      COALESCE(v_computed_name, v_name) || ' (' || COALESCE(v_employee_id, '—')
        || ') has been directly activated (no approval workflow configured). '
        || 'The invite record has been created.',
      '/employees'
    );
  END IF;
END;
$$;

REVOKE ALL    ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-approved employee. '
  'Step 1: employees.status → Active, locked → false. '
  'Step 2: seed employee_personal fallback if missing. '
  'Step 3: flip employee_employment.status → Active in-place. '
  'Step 4 (mig 458): mirror employment satellite → employees base. '
  'Step 4b (mig 463): mirror job relationship satellite → employees base (pm01–om03). '
  'Step 5: record invite. '
  'Step 6: workflow/notification guard.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 463: wf_activate_employee now mirrors job relationships on activation.';
END;
$$;
