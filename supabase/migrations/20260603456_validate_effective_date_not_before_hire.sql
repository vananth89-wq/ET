-- =============================================================================
-- Migration 456 — Validate effective_from >= hire_date in all effective-dated RPCs
--
-- Rule: effective_from must not be before the employee's hire_date.
-- Source of truth: employees.hire_date (the mirror column).
--
-- Applies to:
--   1. upsert_employment_info         — employment satellite
--   2. upsert_personal_info           — personal_info satellite
--   3. fn_apply_dependent_set_transition
--   4. fn_apply_bank_account_set_transition
--   5. fn_apply_job_relationship_set_transition
--
-- For employment: hire_date may also be supplied in p_proposed_data (new hire
-- onboarding). In that case we validate against the incoming hire_date too.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. upsert_employment_info
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_employment_info(
  p_employee_id   uuid,
  p_proposed_data jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target        employee_employment%ROWTYPE;
  v_predecessor   employee_employment%ROWTYPE;
  v_new_id        uuid;
  v_is_delete_record boolean;
  v_is_latest     boolean;
  v_hire_date     date;
  v_dept_id       uuid;
  v_desig_id      uuid;
  v_manager_id    uuid;
  v_loc_id        uuid;
  v_currency_id   uuid;
  v_work_country  uuid;
  v_status_id     uuid;
BEGIN
  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('employee.employment', 'update', p_employee_id)
    OR user_can('employee.employment', 'create', p_employee_id)
    OR is_super_admin()
    OR EXISTS (SELECT 1 FROM workflow_instances wi
               WHERE wi.record_id = p_employee_id
                 AND wi.submitted_by = auth.uid()
                 AND wi.status = 'awaiting_clarification')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: you do not have permission to edit employment information for this employee.');
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
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

  -- ── 3. Hire-date guard ─────────────────────────────────────────────────────
  -- For employment rows the incoming hire_date (if provided) IS the hire date.
  -- Also validate against employees.hire_date when it already exists.
  v_hire_date := NULLIF(p_proposed_data->>'hire_date', '')::date;
  IF v_hire_date IS NULL THEN
    SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  END IF;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Effective date (' || p_effective_from || ') cannot be before the hire date (' || v_hire_date || ').');
  END IF;

  -- ── 4. DELETE_RECORD handling ──────────────────────────────────────────────
  v_is_delete_record := EXISTS (
    SELECT 1 FROM jsonb_each_text(p_proposed_data) v
    WHERE v.value = 'DELETE_RECORD'
  );

  IF v_is_delete_record THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'No employment record found for that effective date.');
    END IF;
    -- Merge deleted slice into predecessor
    SELECT * INTO v_predecessor FROM employee_employment
    WHERE employee_id = p_employee_id AND effective_from < p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN
      UPDATE employee_employment
      SET effective_to = v_target.effective_to, updated_at = NOW()
      WHERE id = v_predecessor.id;
    END IF;
    DELETE FROM employee_employment WHERE id = v_target.id;
    RETURN jsonb_build_object('ok', true, 'case', 'delete');
  END IF;

  -- ── 5. Lock all slices ─────────────────────────────────────────────────────
  PERFORM id FROM employee_employment WHERE employee_id = p_employee_id
  ORDER BY effective_from FOR UPDATE;

  -- ── 6. Case detection ──────────────────────────────────────────────────────
  -- 6a. Exact match → CORRECTION
  SELECT * INTO v_target FROM employee_employment
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  -- 6b. Before first slice → PREPEND
  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target.effective_from THEN
      v_case := 'prepend';
    ELSE
      v_target := NULL;
    END IF;
  END IF;

  -- 6c. Strictly inside a closed historical slice → SPLIT
  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  -- 6d. After open-ended slice → AMENDMENT; no slices → GAP_FILL
  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id = p_employee_id AND effective_to = '9999-12-31'::date
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN
      v_case := 'amendment';
    ELSE
      v_case := 'gap_fill';
    END IF;
  END IF;

  -- ── 7. Resolve lookup codes ────────────────────────────────────────────────
  IF (p_proposed_data->>'dept_code') IS NOT NULL THEN
    SELECT id INTO v_dept_id FROM departments WHERE code = p_proposed_data->>'dept_code';
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Department code not found: ' || (p_proposed_data->>'dept_code'));
    END IF;
  ELSIF v_target IS NOT NULL THEN
    v_dept_id := v_target.dept_id;
  END IF;

  IF (p_proposed_data->>'designation_code') IS NOT NULL THEN
    SELECT id INTO v_desig_id FROM designations WHERE code = p_proposed_data->>'designation_code';
  ELSIF v_target IS NOT NULL THEN
    v_desig_id := v_target.designation_id;
  END IF;

  IF (p_proposed_data->>'manager_employee_code') IS NOT NULL THEN
    SELECT id INTO v_manager_id FROM employees WHERE employee_id = p_proposed_data->>'manager_employee_code';
    IF v_manager_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'An employee cannot be their own manager.');
    END IF;
  ELSIF v_target IS NOT NULL THEN
    v_manager_id := v_target.manager_id;
  END IF;

  IF (p_proposed_data->>'work_location_code') IS NOT NULL THEN
    SELECT id INTO v_loc_id FROM work_locations WHERE code = p_proposed_data->>'work_location_code';
  ELSIF v_target IS NOT NULL THEN
    v_loc_id := v_target.work_location_id;
  END IF;

  IF (p_proposed_data->>'base_currency_code') IS NOT NULL THEN
    SELECT id INTO v_currency_id FROM currencies WHERE code = p_proposed_data->>'base_currency_code';
  ELSIF v_target IS NOT NULL THEN
    v_currency_id := v_target.base_currency_id;
  END IF;

  IF (p_proposed_data->>'work_country_code') IS NOT NULL THEN
    SELECT id INTO v_work_country FROM countries WHERE iso3 = p_proposed_data->>'work_country_code';
  ELSIF v_target IS NOT NULL THEN
    v_work_country := v_target.work_country;
  END IF;

  IF (p_proposed_data->>'status_code') IS NOT NULL THEN
    SELECT id INTO v_status_id FROM employment_statuses WHERE code = p_proposed_data->>'status_code';
  ELSIF v_target IS NOT NULL THEN
    v_status_id := v_target.status_id;
  END IF;

  -- ── 8. Execute by case ─────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_employment SET
      designation_id   = COALESCE(v_desig_id,    v_target.designation_id),
      job_title        = COALESCE(NULLIF(p_proposed_data->>'job_title', ''), v_target.job_title),
      dept_id          = COALESCE(v_dept_id,      v_target.dept_id),
      manager_id       = COALESCE(v_manager_id,   v_target.manager_id),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date, v_target.hire_date),
      end_date         = COALESCE(NULLIF(p_proposed_data->>'end_date',  '')::date, v_target.end_date),
      work_country     = COALESCE(v_work_country,  v_target.work_country),
      work_location_id = COALESCE(v_loc_id,        v_target.work_location_id),
      base_currency_id = COALESCE(v_currency_id,   v_target.base_currency_id),
      status_id        = COALESCE(v_status_id,     v_target.status_id),
      updated_at       = NOW()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, effective_from, effective_to,
      designation_id, job_title, dept_id, manager_id,
      hire_date, end_date, work_country, work_location_id,
      base_currency_id, status_id, is_active
    ) VALUES (
      p_employee_id, p_effective_from, v_target.effective_from - 1,
      COALESCE(v_desig_id,    v_target.designation_id),
      COALESCE(NULLIF(p_proposed_data->>'job_title', ''), v_target.job_title),
      COALESCE(v_dept_id,     v_target.dept_id),
      COALESCE(v_manager_id,  v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date, v_target.hire_date),
      COALESCE(NULLIF(p_proposed_data->>'end_date',  '')::date, v_target.end_date),
      COALESCE(v_work_country, v_target.work_country),
      COALESCE(v_loc_id,       v_target.work_location_id),
      COALESCE(v_currency_id,  v_target.base_currency_id),
      COALESCE(v_status_id,    v_target.status_id),
      false
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_employment
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target.id;

    INSERT INTO employee_employment (
      employee_id, effective_from, effective_to,
      designation_id, job_title, dept_id, manager_id,
      hire_date, end_date, work_country, work_location_id,
      base_currency_id, status_id, is_active
    ) VALUES (
      p_employee_id, p_effective_from, v_target.effective_to,
      COALESCE(v_desig_id,    v_target.designation_id),
      COALESCE(NULLIF(p_proposed_data->>'job_title', ''), v_target.job_title),
      COALESCE(v_dept_id,     v_target.dept_id),
      COALESCE(v_manager_id,  v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date, v_target.hire_date),
      COALESCE(NULLIF(p_proposed_data->>'end_date',  '')::date, v_target.end_date),
      COALESCE(v_work_country, v_target.work_country),
      COALESCE(v_loc_id,       v_target.work_location_id),
      COALESCE(v_currency_id,  v_target.base_currency_id),
      COALESCE(v_status_id,    v_target.status_id),
      false
    ) RETURNING id INTO v_new_id;

  ELSE -- amendment / gap_fill
    IF v_target IS NOT NULL AND v_case = 'amendment' THEN
      UPDATE employee_employment
      SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
      WHERE id = v_target.id;
    END IF;

    INSERT INTO employee_employment (
      employee_id, effective_from, effective_to,
      designation_id, job_title, dept_id, manager_id,
      hire_date, end_date, work_country, work_location_id,
      base_currency_id, status_id, is_active
    ) VALUES (
      p_employee_id, p_effective_from, '9999-12-31'::date,
      COALESCE(v_desig_id,    v_target.designation_id),
      COALESCE(NULLIF(p_proposed_data->>'job_title', ''), v_target.job_title),
      COALESCE(v_dept_id,     v_target.dept_id),
      COALESCE(v_manager_id,  v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date, v_target.hire_date),
      COALESCE(NULLIF(p_proposed_data->>'end_date',  '')::date, v_target.end_date),
      COALESCE(v_work_country, v_target.work_country),
      COALESCE(v_loc_id,       v_target.work_location_id),
      COALESCE(v_currency_id,  v_target.base_currency_id),
      COALESCE(v_status_id,    v_target.status_id),
      true
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 9. Mirror sync — only for most-recent slice ────────────────────────────
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_employment
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  );

  IF v_is_latest THEN
    UPDATE employees SET
      designation_id   = COALESCE(v_desig_id,    (SELECT designation_id FROM employee_employment WHERE id = v_new_id)),
      job_title        = COALESCE(NULLIF(p_proposed_data->>'job_title', ''), (SELECT job_title FROM employee_employment WHERE id = v_new_id)),
      dept_id          = COALESCE(v_dept_id,      (SELECT dept_id FROM employee_employment WHERE id = v_new_id)),
      manager_id       = COALESCE(v_manager_id,   (SELECT manager_id FROM employee_employment WHERE id = v_new_id)),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date, (SELECT hire_date FROM employee_employment WHERE id = v_new_id)),
      work_country     = COALESCE(v_work_country,  (SELECT work_country FROM employee_employment WHERE id = v_new_id)),
      work_location_id = COALESCE(v_loc_id,        (SELECT work_location_id FROM employee_employment WHERE id = v_new_id)),
      base_currency_id = COALESCE(v_currency_id,   (SELECT base_currency_id FROM employee_employment WHERE id = v_new_id)),
      status_id        = COALESCE(v_status_id,     (SELECT status_id FROM employee_employment WHERE id = v_new_id)),
      updated_at       = NOW()
    WHERE id = p_employee_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'case', v_case, 'employment_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date) IS
  'Mig 456: added hire-date guard — effective_from cannot be before hire_date.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. upsert_personal_info  — add hire-date guard
-- ─────────────────────────────────────────────────────────────────────────────
-- Patch only the validation section; rest of function is unchanged from mig 454.
-- We replace the function entirely to insert the check cleanly.

CREATE OR REPLACE FUNCTION upsert_personal_info(
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
  v_case    text;
  v_target  employee_personal%ROWTYPE;
  v_current employee_personal%ROWTYPE;
  v_first   employee_personal%ROWTYPE;
  v_new_id  uuid;
  v_is_latest boolean;
  v_hire_date date;
BEGIN
  -- ── 1. Permission check ────────────────────────────────────────────────────
  IF NOT (
    user_can('employee.personal_info', 'update', p_employee_id)
    OR user_can('employee.personal_info', 'create', p_employee_id)
    OR is_super_admin()
    OR EXISTS (SELECT 1 FROM workflow_instances wi
               WHERE wi.record_id = p_employee_id
                 AND wi.submitted_by = auth.uid()
                 AND wi.status = 'awaiting_clarification')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: you do not have permission to edit personal information for this employee.');
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Hire-date guard ─────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'Effective date (' || p_effective_from || ') cannot be before the hire date (' || v_hire_date || ').');
  END IF;

  -- ── 4. Lock all slices ─────────────────────────────────────────────────────
  PERFORM id FROM employee_personal WHERE employee_id = p_employee_id
  ORDER BY effective_from FOR UPDATE;

  -- ── 5. Case detection ──────────────────────────────────────────────────────
  SELECT * INTO v_target FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_personal
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case := 'prepend'; v_target := v_first;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_personal
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_personal
    WHERE employee_id = p_employee_id AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment';
    v_target := v_current;
  END IF;

  -- ── 6. Execute by case ─────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_personal SET
      first_name         = COALESCE(NULLIF(p_proposed_data->>'first_name',         ''), v_target.first_name),
      last_name          = COALESCE(NULLIF(p_proposed_data->>'last_name',          ''), v_target.last_name),
      middle_name        = COALESCE(NULLIF(p_proposed_data->>'middle_name',        ''), v_target.middle_name),
      preferred_name     = COALESCE(NULLIF(p_proposed_data->>'preferred_name',     ''), v_target.preferred_name),
      date_of_birth      = COALESCE(NULLIF(p_proposed_data->>'date_of_birth',      '')::date, v_target.date_of_birth),
      gender             = COALESCE(NULLIF(p_proposed_data->>'gender',             ''), v_target.gender),
      nationality        = COALESCE(NULLIF(p_proposed_data->>'nationality',        ''), v_target.nationality),
      marital_status     = COALESCE(NULLIF(p_proposed_data->>'marital_status',     ''), v_target.marital_status),
      updated_at         = NOW()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_personal (
      employee_id, effective_from, effective_to, is_active,
      first_name, last_name, middle_name, preferred_name,
      date_of_birth, gender, nationality, marital_status
    ) VALUES (
      p_employee_id, p_effective_from, v_target.effective_from - 1, true,
      COALESCE(NULLIF(p_proposed_data->>'first_name',     ''), v_target.first_name),
      COALESCE(NULLIF(p_proposed_data->>'last_name',      ''), v_target.last_name),
      NULLIF(p_proposed_data->>'middle_name',   ''),
      NULLIF(p_proposed_data->>'preferred_name',''),
      NULLIF(p_proposed_data->>'date_of_birth', '')::date,
      NULLIF(p_proposed_data->>'gender',        ''),
      NULLIF(p_proposed_data->>'nationality',   ''),
      NULLIF(p_proposed_data->>'marital_status','')
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_personal
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target.id;
    INSERT INTO employee_personal (
      employee_id, effective_from, effective_to, is_active,
      first_name, last_name, middle_name, preferred_name,
      date_of_birth, gender, nationality, marital_status
    ) VALUES (
      p_employee_id, p_effective_from, v_target.effective_to, false,
      COALESCE(NULLIF(p_proposed_data->>'first_name',     ''), v_target.first_name),
      COALESCE(NULLIF(p_proposed_data->>'last_name',      ''), v_target.last_name),
      COALESCE(NULLIF(p_proposed_data->>'middle_name',   ''), v_target.middle_name),
      COALESCE(NULLIF(p_proposed_data->>'preferred_name',''), v_target.preferred_name),
      COALESCE(NULLIF(p_proposed_data->>'date_of_birth', '')::date, v_target.date_of_birth),
      COALESCE(NULLIF(p_proposed_data->>'gender',        ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'nationality',   ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status',''), v_target.marital_status)
    ) RETURNING id INTO v_new_id;

  ELSE -- amendment / gap_fill
    IF v_target.id IS NOT NULL THEN
      UPDATE employee_personal
      SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
      WHERE id = v_target.id;
    END IF;
    INSERT INTO employee_personal (
      employee_id, effective_from, effective_to, is_active,
      first_name, last_name, middle_name, preferred_name,
      date_of_birth, gender, nationality, marital_status
    ) VALUES (
      p_employee_id, p_effective_from, '9999-12-31'::date, true,
      COALESCE(NULLIF(p_proposed_data->>'first_name',     ''), v_target.first_name),
      COALESCE(NULLIF(p_proposed_data->>'last_name',      ''), v_target.last_name),
      COALESCE(NULLIF(p_proposed_data->>'middle_name',   ''), v_target.middle_name),
      COALESCE(NULLIF(p_proposed_data->>'preferred_name',''), v_target.preferred_name),
      COALESCE(NULLIF(p_proposed_data->>'date_of_birth', '')::date, v_target.date_of_birth),
      COALESCE(NULLIF(p_proposed_data->>'gender',        ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'nationality',   ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status',''), v_target.marital_status)
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 7. Mirror sync — only for most-recent slice ────────────────────────────
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  );
  IF v_is_latest THEN
    UPDATE employees SET
      first_name     = COALESCE(NULLIF(p_proposed_data->>'first_name',     ''), employees.first_name),
      last_name      = COALESCE(NULLIF(p_proposed_data->>'last_name',      ''), employees.last_name),
      middle_name    = COALESCE(NULLIF(p_proposed_data->>'middle_name',    ''), employees.middle_name),
      preferred_name = COALESCE(NULLIF(p_proposed_data->>'preferred_name', ''), employees.preferred_name),
      updated_at     = NOW()
    WHERE id = p_employee_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'case', v_case, 'personal_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Mig 456: added hire-date guard — effective_from cannot be before hire_date.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. fn_apply_dependent_set_transition — add hire-date guard
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_apply_dependent_set_transition(
  p_employee_id    uuid,
  p_effective_from date,
  p_dependents     jsonb,
  p_actor          uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target_id     uuid;
  v_target_eff_from date;
  v_inherited_end date;
  v_new_set_id    uuid;
  v_dep           jsonb;
  v_hire_date     date;
BEGIN
  -- ── Hire-date guard ────────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_dependent_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    ELSE v_target_id := NULL; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id AND is_active = true
      AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_dependent WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_dependent_set
    SET effective_to = p_effective_from - 1, is_active = false,
        updated_at = NOW(), updated_by = p_actor
    WHERE id = v_target_id;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set
        SET effective_to = p_effective_from - 1, is_active = false,
            updated_at = NOW(), updated_by = p_actor
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert dependent rows ──────────────────────────────────────────────────
  FOR v_dep IN SELECT * FROM jsonb_array_elements(p_dependents) LOOP
    INSERT INTO employee_dependent (
      set_id, first_name, last_name, relationship,
      date_of_birth, gender, nationality, is_emergency_contact
    ) VALUES (
      v_new_set_id,
      v_dep->>'first_name', v_dep->>'last_name', v_dep->>'relationship',
      NULLIF(v_dep->>'date_of_birth', '')::date,
      NULLIF(v_dep->>'gender', ''),
      NULLIF(v_dep->>'nationality', ''),
      COALESCE((v_dep->>'is_emergency_contact')::boolean, false)
    );
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 456: added hire-date guard — effective_from cannot be before hire_date.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. fn_apply_bank_account_set_transition — add hire-date guard
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_apply_bank_account_set_transition(
  p_employee_id    uuid,
  p_effective_from date,
  p_items          jsonb,
  p_actor          uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target_id     uuid;
  v_target_eff_from date;
  v_inherited_end date;
  v_new_set_id    uuid;
  v_item          jsonb;
  v_group_id      uuid;
  v_hire_date     date;
BEGIN
  -- ── Hire-date guard ────────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_bank_account_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    ELSE v_target_id := NULL; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id AND is_active = true
      AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_bank_account_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_bank_account_set
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_bank_account_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_bank_account_set
        SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;
    INSERT INTO employee_bank_account_item (
      set_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code,
      account_holder_name, account_number,
      ifsc_code, iban, swift_bic, is_primary
    ) VALUES (
      v_new_set_id, v_group_id,
      v_item->>'country_code', v_item->>'currency_code',
      v_item->>'bank_name', v_item->>'branch_name', v_item->>'branch_code',
      v_item->>'account_holder_name', v_item->>'account_number',
      NULLIF(v_item->>'ifsc_code',  ''),
      NULLIF(v_item->>'iban',       ''),
      NULLIF(v_item->>'swift_bic',  ''),
      COALESCE((v_item->>'is_primary')::boolean, false)
    );
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 456: added hire-date guard — effective_from cannot be before hire_date.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. fn_apply_job_relationship_set_transition — add hire-date guard
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_apply_job_relationship_set_transition(
  p_employee_id    uuid,
  p_effective_from date,
  p_items          jsonb,
  p_actor          uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target_id     uuid;
  v_target_eff_from date;
  v_inherited_end date;
  v_new_set_id    uuid;
  v_item          jsonb;
  v_manager_id    uuid;
  v_hire_date     date;
BEGIN
  -- ── Hire-date guard ────────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_job_relationship_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_job_relationship_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_job_relationship_set
    SET effective_to = p_effective_from - 1, is_active = false,
        updated_at = NOW(), updated_by = p_actor
    WHERE id = v_target_id;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_job_relationship_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_job_relationship_set
        SET effective_to = p_effective_from - 1, is_active = false,
            updated_at = NOW(), updated_by = p_actor
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id INTO v_manager_id FROM employees
    WHERE employee_id = v_item->>'manager_employee_id';

    IF v_manager_id IS NULL THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: manager % not found',
        v_item->>'manager_employee_id';
    END IF;
    IF v_manager_id = p_employee_id THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: self-assignment not allowed';
    END IF;

    INSERT INTO employee_job_relationship_item (
      set_id, relationship_code, manager_employee_id
    ) VALUES (v_new_set_id, v_item->>'relationship_code', v_manager_id);
  END LOOP;

  -- ── Mirror sync — only if most-recent set ─────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND NOT EXISTS (
    SELECT 1 FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  ) THEN
    PERFORM sync_job_relationship_mirrors(p_employee_id, v_new_set_id);
  END IF;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_job_relationship_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 456: added hire-date guard — effective_from cannot be before hire_date.';

-- =============================================================================
-- END OF MIGRATION 456
-- =============================================================================
