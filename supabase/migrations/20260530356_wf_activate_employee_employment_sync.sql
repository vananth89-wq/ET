-- =============================================================================
-- Migration 356 — Patch wf_activate_employee to sync employee_employment.status
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- After mig 351-355 landed, employee_employment is the satellite source of
-- truth for employment status. When wf_activate_employee fires (Draft/Pending
-- → Active), it updates employees.status via a direct UPDATE. The guard trigger
-- allows this because the employee is still in an onboarding status.
--
-- However, the satellite slice written by the hire wizard (via saveExtendedData
-- calling upsert_employment_info, mig 352) still has status = 'Draft' or
-- 'Incomplete'. We need to flip it to 'Active' so the satellite stays in sync.
--
-- CHANGE
-- ──────
-- Add a block inside wf_activate_employee (after the employees UPDATE) that:
--   1. Looks up the current open-ended slice in employee_employment.
--   2. If found and status != 'Active', updates it to 'Active' in-place.
--   3. Also seeds an employee_employment slice if none exists yet (fallback
--      for hires created before mig 351 or for any missed saveExtendedData).
--
-- This is the "same-day lifecycle transition updates status in-place" behaviour
-- described in the design spec §4.1.
--
-- DESIGN REF: docs/employment-effective-dating-design.md §4.1, §8 (Phase 8)
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

  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Seed employee_personal if not already present.
  -- Since mig 317, AddEmployee writes directly to employee_personal via
  -- upsert_personal_info during the hire pipeline, so this row almost always
  -- exists by activation time. Fallback handles legacy / skipped-section cases.
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
      p_employee_id,
      v_computed_name,
      v_first_name,
      v_last_name,
      COALESCE(v_hire_date, CURRENT_DATE),
      '9999-12-31'::date,
      true,
      auth.uid(),
      auth.uid()
    );
  END IF;

  -- ── NEW (mig 356): Sync employee_employment.status → 'Active' ──────────────
  -- Same-day lifecycle transition (design spec §4.1): update the current open-ended
  -- slice in-place rather than creating a new slice.
  IF EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    -- Flip status in-place on the current slice
    UPDATE employee_employment
    SET    status     = 'Active',
           updated_at = NOW()
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
      AND  status      != 'Active';  -- no-op if already Active

  ELSE
    -- Fallback: no satellite row yet (employee created before mig 351 or
    -- saveExtendedData didn't write employment). Seed from employees master.
    DECLARE
      v_emp employees%ROWTYPE;
    BEGIN
      SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;

      -- Allow the insert — guard trigger is not on employee_employment
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
        status,
        effective_from,
        effective_to,
        is_active,
        created_by,
        updated_by
      ) VALUES (
        p_employee_id,
        v_emp.designation,
        v_emp.job_title,
        v_emp.dept_id,
        v_emp.manager_id,
        v_emp.hire_date,
        v_emp.end_date,
        v_emp.work_country,
        v_emp.work_location,
        v_emp.base_currency_id,
        'Active',
        COALESCE(v_emp.hire_date, CURRENT_DATE),
        '9999-12-31'::date,
        true,
        auth.uid(),
        auth.uid()
      )
      ON CONFLICT DO NOTHING;  -- partial unique index prevents duplicate if race
    END;
  END IF;
  -- ── END mig 356 ────────────────────────────────────────────────────────────

  -- Record invite
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
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
  'Sets employees.status = Active, locked = false. '
  'Flips employee_employment.status → Active in-place (same-day lifecycle transition). '
  'Seeds employee_personal fallback if missing (mig 317 handles the normal case). '
  'Seeds employee_employment fallback if missing (mig 352 handles the normal case). '
  'Mig 356: added employee_employment.status sync on activation.';
