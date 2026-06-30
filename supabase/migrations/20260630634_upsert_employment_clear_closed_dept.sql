-- =============================================================================
-- Mig 634: upsert_employment_info — null out inherited dept_id if department
--          is closed (end_date < p_effective_from) on new slice inserts.
--
-- Departments use start_date / end_date for date-effectiveness (no active flag).
-- When inserting a new employment slice, the inherited dept_id from the previous
-- slice must be validated against the new effective_from date. If the department
-- closed before the new slice starts, it should not carry forward.
--
-- Scope: non-correction cases only (amendment / gap_fill / split / prepend).
--        Correction edits of historical records are intentionally excluded.
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_employment_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date    DEFAULT CURRENT_DATE,
  p_propagate      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target          employee_employment%ROWTYPE;
  v_first           employee_employment%ROWTYPE;
  v_current         employee_employment%ROWTYPE;
  v_case            text;
  v_new_id          uuid;
  v_is_system_path  boolean := false;
  v_existing_status employee_status;
  v_new_status      employee_status;
  v_designation     text;
  v_job_title       text;
  v_desig_label     text;
  v_manager_id      uuid;
  v_work_country    text;
  v_work_location   text;
  v_currency_name   text;
  v_currency_pl_id  uuid;
  v_currency_id     uuid;
  v_location_parent text;
  v_check_id        uuid;
  v_cycle_chain     text[];
  v_dept_end_date   date;
BEGIN

  -- ── 1a. Layer-A: coarse access guard ──────────────────────────────────────
  IF user_can('employment', 'bulk_import', NULL) THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.entity_id   = p_employee_id
        AND wi.module_code IN ('employee_hire','employee_onboarding')
        AND wi.status      IN ('draft','pending','incomplete')
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_task_assignments wta
      JOIN workflow_instances wi ON wi.id = wta.instance_id
      WHERE wi.entity_id  = p_employee_id
        AND wta.assignee_id = auth.uid()
        AND wta.status      = 'pending'
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.entity_id   = p_employee_id
        AND wi.status      = 'awaiting_clarification'
        AND wi.initiated_by = auth.uid()
    ) THEN v_is_system_path := true; END IF;
  END IF;

  IF NOT v_is_system_path THEN
    IF NOT (
      user_can('employment', 'edit',   p_employee_id)
      OR user_can('employment', 'create', p_employee_id)
      OR (p_employee_id = get_my_employee_id()
          AND (has_permission('employment.edit') OR has_permission('employment.create')))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: employment permission required.');
    END IF;
  END IF;

  -- ── 5. Case detection ──────────────────────────────────────────────────────
  SELECT * INTO v_target FROM employee_employment
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_employment
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case := 'prepend'; v_target := v_first;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id   = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_employment
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true;
    IF FOUND THEN
      v_case := 'amendment'; v_target := v_current;
    ELSE
      v_case := 'gap_fill';
      SELECT * INTO v_target FROM employee_employment
      WHERE employee_id = p_employee_id ORDER BY effective_from DESC LIMIT 1;
    END IF;
  END IF;

  -- ── 1b. Layer-B: fine-grained ─────────────────────────────────────────────
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      IF NOT (
        user_can('employment', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('employment.edit'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: employment.edit permission is required to edit an existing employment record.');
      END IF;
    ELSE
      IF NOT (
        user_can('employment', 'create', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('employment.create'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: employment.create permission is required to insert a new employment record.');
      END IF;
    END IF;
  END IF;

  -- ── 6. Manager cycle check ─────────────────────────────────────────────────
  v_manager_id := NULLIF(p_proposed_data->>'manager_id', '')::uuid;
  IF v_manager_id IS NOT NULL THEN
    IF v_manager_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'An employee cannot be their own manager.');
    END IF;
    v_check_id    := v_manager_id;
    v_cycle_chain := ARRAY[p_employee_id::text, v_manager_id::text];
    FOR _ IN 1..50 LOOP
      SELECT manager_id INTO v_check_id FROM employees WHERE id = v_check_id;
      EXIT WHEN v_check_id IS NULL;
      IF v_check_id = p_employee_id THEN
        RETURN jsonb_build_object('ok', false, 'error', 'CYCLE_DETECTED',
          'message', 'Assigning this manager would create a reporting cycle.',
          'chain', to_jsonb(v_cycle_chain));
      END IF;
      v_cycle_chain := v_cycle_chain || v_check_id::text;
    END LOOP;
  END IF;

  -- ── 6b. Clear inherited manager if inactive (mig 633) ─────────────────────
  IF v_case != 'correction' AND v_manager_id IS NULL AND v_target.manager_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM employees WHERE id = v_target.manager_id AND status = 'Inactive'
    ) THEN
      v_target.manager_id := NULL;
    END IF;
  END IF;

  -- ── 6c. Clear inherited dept if closed on effective_from (mig 634) ─────────
  IF v_case != 'correction'
     AND NULLIF(p_proposed_data->>'dept_id', '') IS NULL   -- dept not explicitly supplied
     AND v_target.dept_id IS NOT NULL THEN
    SELECT end_date INTO v_dept_end_date
    FROM departments WHERE id = v_target.dept_id;
    IF v_dept_end_date IS NOT NULL
       AND v_dept_end_date != '9999-12-31'::date
       AND v_dept_end_date < p_effective_from THEN
      v_target.dept_id := NULL;
    END IF;
  END IF;

  -- ── 7. work_location parent validation ────────────────────────────────────
  IF (p_proposed_data->>'work_location') IS NOT NULL
  AND (p_proposed_data->>'work_country') IS NOT NULL THEN
    SELECT (parent_value_id)::text INTO v_location_parent
    FROM picklist_values WHERE id = (p_proposed_data->>'work_location')::uuid;
    IF v_location_parent IS DISTINCT FROM (p_proposed_data->>'work_country') THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'work_location does not belong to the selected work_country.');
    END IF;
  END IF;

  -- ── 8. Derive fields ───────────────────────────────────────────────────────
  SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;

  v_designation   := NULLIF(p_proposed_data->>'designation', '');
  v_work_country  := COALESCE(NULLIF(p_proposed_data->>'work_country', ''), v_target.work_country);
  v_work_location := NULLIF(p_proposed_data->>'work_location', '');

  SELECT (meta->>'currencyId')::uuid INTO v_currency_pl_id
  FROM picklist_values WHERE id = v_work_country::uuid;
  IF v_currency_pl_id IS NOT NULL THEN
    SELECT value INTO v_currency_name FROM picklist_values WHERE id = v_currency_pl_id;
  END IF;
  IF v_currency_name IS NOT NULL THEN
    SELECT id INTO v_currency_id FROM currencies WHERE name = v_currency_name AND active = true LIMIT 1;
  END IF;
  IF v_work_country IS NOT NULL AND v_currency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active currency found for the selected country.');
  END IF;

  v_job_title := NULLIF(p_proposed_data->>'job_title', '');
  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label FROM picklist_values WHERE id = v_designation::uuid;
    v_job_title := COALESCE(v_desig_label, v_target.job_title);
  ELSIF v_job_title IS NULL THEN
    v_job_title := v_target.job_title;
  END IF;

  v_new_status := COALESCE(
    NULLIF(p_proposed_data->>'status', '')::employee_status,
    v_target.status, v_existing_status, 'Active'::employee_status
  );

  -- ── 9. Execute by case ────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_employment SET
      designation        = v_designation,
      job_title          = v_job_title,
      dept_id            = COALESCE(NULLIF(p_proposed_data->>'dept_id', '')::uuid, v_target.dept_id),
      manager_id         = COALESCE(v_manager_id, v_target.manager_id),
      hire_date          = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country       = v_work_country,
      work_location      = COALESCE(v_work_location, v_target.work_location),
      base_currency_id   = COALESCE(v_currency_id, v_target.base_currency_id),
      status             = v_new_status,
      probation_end_date = COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      notice_period_days = COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
      updated_at         = NOW(), updated_by = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
      p_effective_from, v_target.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    DECLARE v_inherited_end date := v_target.effective_to; BEGIN
      UPDATE employee_employment
      SET effective_to = p_effective_from - interval '1 day',
          updated_at = NOW(), updated_by = auth.uid()
      WHERE id = v_target.id;
      INSERT INTO employee_employment (
        employee_id, designation, job_title, dept_id, manager_id,
        hire_date, work_country, work_location, base_currency_id,
        status, probation_end_date, notice_period_days,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_designation, v_job_title,
        COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
        COALESCE(v_manager_id, v_target.manager_id),
        COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
        v_work_country, COALESCE(v_work_location, v_target.work_location),
        COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
        COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
        COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
        p_effective_from, v_inherited_end,
        v_target.is_active, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;
    END;

  ELSIF v_case IN ('amendment', 'gap_fill') THEN
    IF v_case = 'amendment' THEN
      IF v_current.effective_from >= p_effective_from THEN
        DELETE FROM employee_employment WHERE id = v_current.id;
      ELSE
        UPDATE employee_employment
        SET effective_to = p_effective_from - interval '1 day',
            is_active = false, inactive_at = NOW(),
            updated_at = NOW(), updated_by = auth.uid()
        WHERE id = v_current.id;
      END IF;
    END IF;
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
      p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 10. Propagation ───────────────────────────────────────────────────────
  IF p_propagate THEN
    UPDATE employee_employment
    SET
      designation = CASE
        WHEN (p_proposed_data ? 'designation') AND NULLIF(p_proposed_data->>'designation','') IS NOT NULL
        THEN v_designation ELSE designation END,
      job_title = CASE
        WHEN (p_proposed_data ? 'job_title') AND NULLIF(p_proposed_data->>'job_title','') IS NOT NULL
        THEN v_job_title ELSE job_title END,
      dept_id = CASE
        WHEN (p_proposed_data ? 'dept_id') AND NULLIF(p_proposed_data->>'dept_id','') IS NOT NULL
        THEN (p_proposed_data->>'dept_id')::uuid ELSE dept_id END,
      manager_id = CASE
        WHEN v_manager_id IS NOT NULL
        THEN v_manager_id ELSE manager_id END,
      work_country = CASE
        WHEN (p_proposed_data ? 'work_country') AND NULLIF(p_proposed_data->>'work_country','') IS NOT NULL
        THEN v_work_country ELSE work_country END,
      work_location = CASE
        WHEN (p_proposed_data ? 'work_location') AND NULLIF(p_proposed_data->>'work_location','') IS NOT NULL
        THEN v_work_location ELSE work_location END,
      base_currency_id = CASE
        WHEN (p_proposed_data ? 'work_country') AND NULLIF(p_proposed_data->>'work_country','') IS NOT NULL
             AND v_currency_id IS NOT NULL
        THEN v_currency_id ELSE base_currency_id END,
      notice_period_days = CASE
        WHEN (p_proposed_data ? 'notice_period_days') AND NULLIF(p_proposed_data->>'notice_period_days','') IS NOT NULL
        THEN (p_proposed_data->>'notice_period_days')::integer ELSE notice_period_days END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 11. Sync employees head record ────────────────────────────────────────
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  UPDATE employees
  SET
    designation      = v_designation,
    job_title        = v_job_title,
    dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, dept_id),
    manager_id       = COALESCE(v_manager_id, manager_id),
    hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, hire_date),
    work_country     = v_work_country,
    work_location    = COALESCE(v_work_location, work_location),
    base_currency_id = COALESCE(v_currency_id, base_currency_id),
    updated_at       = NOW()
  WHERE id = p_employee_id
    AND (
      p_effective_from = (
        SELECT MAX(effective_from) FROM employee_employment WHERE employee_id = p_employee_id
      )
      OR v_case = 'amendment'
    );

  RETURN jsonb_build_object('ok', true, 'id', v_new_id, 'case', v_case);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;
