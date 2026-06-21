-- =============================================================================
-- Migration 358 — upsert_employment_info: add hire pipeline access path
-- =============================================================================
-- Same latent bug as upsert_personal_info (fixed in mig 357):
-- Brand-new Draft employees are not yet in target_group_members, so
-- user_can('employment','edit', p_employee_id) returns false.
-- The hire wizard's saveExtendedData call to upsert_employment_info would
-- silently fail with 'Access denied' for fresh Draft hires.
--
-- Fix: add the hire pipeline path — if the caller has global employment.edit
-- + hire_employee.edit AND the target is Draft/Incomplete/Pending, allow it.
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_employment_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_row     employee_employment%ROWTYPE;
  v_new_id          uuid;
  v_is_amendment    boolean;

  -- Currency derivation
  v_work_country    text;
  v_currency_pl_id  uuid;
  v_currency_name   text;
  v_currency_id     uuid;

  -- Manager cycle check
  v_manager_id      uuid;
  v_check_id        uuid;
  v_hops            int := 0;
  v_cycle_chain     text[] := ARRAY[]::text[];

  -- Designation / job_title auto-fill
  v_designation     text;
  v_job_title       text;
  v_desig_label     text;

  -- End-date / status
  v_end_date        date;
  v_new_status      employee_status;

  -- Mirror sync
  v_new_manager_profile_id uuid;
  v_old_manager_id  uuid;

  -- Dept validation
  v_dept_exists     boolean;

  -- work_location validation
  v_location_parent text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Path A: HR/admin scoped via target_group
  -- Path B: Hire pipeline — new Draft employee not yet in target_group_members
  -- Path C: ESS self-edit
  -- Path D: Approver holds a pending task for this employee
  -- Path E: Submitter whose request was sent back
  IF NOT (
    user_can('employment', 'edit', p_employee_id)
    OR (
      user_can('employment',    'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = p_employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employment.edit')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'Access denied: you do not have permission to edit employment information for this employee.'
    );
  END IF;

  -- ── 2. Input validation ───────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  IF (p_proposed_data->>'end_date') IS NOT NULL AND (p_proposed_data->>'hire_date') IS NOT NULL THEN
    IF (p_proposed_data->>'end_date')::date < (p_proposed_data->>'hire_date')::date THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date must be on or after hire_date.');
    END IF;
  END IF;

  IF (p_proposed_data->>'dept_id') IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM departments
      WHERE id = (p_proposed_data->>'dept_id')::uuid AND deleted_at IS NULL
    ) INTO v_dept_exists;
    IF NOT v_dept_exists THEN
      RETURN jsonb_build_object('ok', false, 'error', 'dept_id does not exist or has been deleted.');
    END IF;
  END IF;

  -- ── 3. Manager cycle check ────────────────────────────────────────────────

  v_manager_id := NULLIF(p_proposed_data->>'manager_id', '')::uuid;

  IF v_manager_id IS NOT NULL THEN
    IF v_manager_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'An employee cannot be their own manager.');
    END IF;

    v_check_id    := v_manager_id;
    v_cycle_chain := ARRAY[p_employee_id::text, v_manager_id::text];

    LOOP
      EXIT WHEN v_hops >= 10;
      v_hops := v_hops + 1;

      SELECT manager_id INTO v_check_id
      FROM   employees
      WHERE  id = v_check_id AND deleted_at IS NULL;

      EXIT WHEN v_check_id IS NULL;

      v_cycle_chain := v_cycle_chain || v_check_id::text;

      IF v_check_id = p_employee_id THEN
        RETURN jsonb_build_object(
          'ok',     false,
          'error',  'CYCLE_DETECTED',
          'message', 'Assigning this manager would create a reporting cycle.',
          'chain',  to_jsonb(v_cycle_chain)
        );
      END IF;
    END LOOP;
  END IF;

  -- ── 4. work_location parent validation ───────────────────────────────────

  IF (p_proposed_data->>'work_location') IS NOT NULL AND (p_proposed_data->>'work_country') IS NOT NULL THEN
    SELECT (parent_value_id)::text
    INTO   v_location_parent
    FROM   picklist_values
    WHERE  id = (p_proposed_data->>'work_location')::uuid;

    IF v_location_parent IS DISTINCT FROM (p_proposed_data->>'work_country') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'work_location does not belong to the selected work_country.');
    END IF;
  END IF;

  -- ── 5. Fetch current open-ended row ───────────────────────────────────────

  SELECT * INTO v_current_row
  FROM   employee_employment
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 6. Overlap guard ──────────────────────────────────────────────────────

  IF EXISTS (
    SELECT 1
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  is_active    = true
      AND  effective_to < '9999-12-31'::date
      AND  effective_to >= p_effective_from
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'The chosen effective date overlaps with an existing historical record. Choose a later date.'
    );
  END IF;

  -- ── 7. Amendment: close or replace the current open-ended row ─────────────

  IF v_is_amendment THEN
    IF v_current_row.effective_from >= p_effective_from THEN
      DELETE FROM employee_employment WHERE id = v_current_row.id;
    ELSE
      UPDATE employee_employment
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 8. Resolve derived fields ─────────────────────────────────────────────

  v_work_country := COALESCE(NULLIF(p_proposed_data->>'work_country', ''), v_current_row.work_country);

  SELECT (meta->>'currencyId')::uuid INTO v_currency_pl_id
  FROM   picklist_values WHERE id = v_work_country::uuid;

  IF v_currency_pl_id IS NOT NULL THEN
    SELECT value INTO v_currency_name FROM picklist_values WHERE id = v_currency_pl_id;
  END IF;

  IF v_currency_name IS NOT NULL THEN
    SELECT id INTO v_currency_id FROM currencies WHERE name = v_currency_name AND active = true LIMIT 1;
  END IF;

  IF v_work_country IS NOT NULL AND v_currency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'CURRENCY_DERIVATION_FAILED', 'country', v_work_country);
  END IF;

  v_designation := COALESCE(NULLIF(p_proposed_data->>'designation', ''), v_current_row.designation);
  v_job_title   := NULLIF(p_proposed_data->>'job_title', '');

  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label FROM picklist_values WHERE id = v_designation::uuid;
    v_job_title := COALESCE(v_desig_label, v_current_row.job_title);
  ELSIF v_job_title IS NULL THEN
    v_job_title := v_current_row.job_title;
  END IF;

  v_end_date := COALESCE(NULLIF(p_proposed_data->>'end_date', '')::date, v_current_row.end_date);

  v_new_status := COALESCE(NULLIF(p_proposed_data->>'status', '')::employee_status, v_current_row.status);

  IF v_end_date IS NOT NULL
     AND p_effective_from <= CURRENT_DATE
     AND v_end_date        <= CURRENT_DATE
     AND v_new_status       = 'Active'
  THEN
    v_new_status := 'Inactive';
  END IF;

  -- ── 9. Insert new slice ───────────────────────────────────────────────────

  INSERT INTO employee_employment (
    employee_id, designation, job_title, dept_id, manager_id,
    hire_date, end_date, work_country, work_location, base_currency_id,
    status, probation_end_date, effective_from, effective_to, is_active,
    created_by, updated_by
  ) VALUES (
    p_employee_id,
    v_designation,
    v_job_title,
    COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_current_row.dept_id),
    COALESCE(v_manager_id, v_current_row.manager_id),
    COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_current_row.hire_date),
    v_end_date,
    v_work_country,
    COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_current_row.work_location),
    COALESCE(v_currency_id, v_current_row.base_currency_id),
    v_new_status,
    COALESCE(NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_current_row.probation_end_date),
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 10. Mirror sync ───────────────────────────────────────────────────────

  IF p_effective_from <= CURRENT_DATE THEN
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);

    v_old_manager_id := v_current_row.manager_id;

    UPDATE employees
    SET
      designation      = v_designation,
      job_title        = v_job_title,
      dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_current_row.dept_id),
      manager_id       = COALESCE(v_manager_id, v_current_row.manager_id),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_current_row.hire_date),
      end_date         = v_end_date,
      work_country     = v_work_country,
      work_location    = COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_current_row.work_location),
      base_currency_id = COALESCE(v_currency_id, v_current_row.base_currency_id),
      status           = v_new_status,
      updated_at       = now()
    WHERE id = p_employee_id;

    IF (COALESCE(v_manager_id, v_current_row.manager_id)) IS DISTINCT FROM v_old_manager_id THEN
      SELECT p.id INTO v_new_manager_profile_id
      FROM   profiles p
      WHERE  p.employee_id = COALESCE(v_manager_id, v_current_row.manager_id)
        AND  p.is_active   = true
      LIMIT  1;

      IF v_new_manager_profile_id IS NOT NULL THEN
        PERFORM sync_system_roles();
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'employment_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date) IS
  'Effective-dated employment info upsert. '
  'Mig 358: added hire pipeline access path (same fix as upsert_personal_info mig 357). '
  'Brand-new Draft employees are not yet in target_group_members; the hire pipeline '
  'path allows HR admins to write employment info during onboarding.';

REVOKE ALL     ON FUNCTION upsert_employment_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_employment_info(uuid, jsonb, date) TO authenticated;
