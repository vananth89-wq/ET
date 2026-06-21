-- =============================================================================
-- Migration 485 — Remove end_date from employee_employment (and employees mirror)
--
-- CONTEXT
-- ───────
-- end_date on employee_employment modelled "planned contract end date" and drove
-- an auto-inactivation heuristic in upsert_employment_info. With the Termination
-- module (mig 482–484) now owning all separation events as workflow-gated
-- transactions, end_date is redundant and its auto-inactivation logic conflicts
-- with the Termination module's controlled inactivation path.
--
-- WHAT CHANGES
-- ─────────────
-- 1. upsert_employment_info   — remove v_end_date, validation, auto-inactivation,
--                               all INSERT/UPDATE column references
-- 2. _sync_employment_today   — remove end_date from SELECT, drift check, UPDATE
-- 3. wf_activate_employee     — remove end_date from satellite mirror & fallback INSERT
-- 4. _bulk_export_employment  — remove "End Date" column from both history and current modes
-- 5. bulk_template_registry   — remove "End Date" from employment schema_definition
-- 6. ALTER TABLE employee_employment DROP COLUMN end_date
-- 7. ALTER TABLE employees       DROP COLUMN end_date
--
-- BEHAVIOURAL NOTE
-- ────────────────
-- The auto-inactivation that previously triggered when end_date <= CURRENT_DATE
-- is intentionally removed. Status transitions to Inactive must now go through
-- either the Termination workflow (mig 482) or an explicit employment satellite
-- edit (status field set manually to Inactive).
--
-- Predecessor: 20260604484 (termination picklists + permissions)
-- Next migration: 20260604486 (termination RPCs — Phase 2)
-- =============================================================================


-- =============================================================================
-- 1. upsert_employment_info — end_date references stripped
--    Source: mig 460 (most recent authoritative version)
--    Changes: removed v_end_date var, end_date validation, auto-inactivation block,
--    all end_date columns in INSERT/UPDATE (6 sites), employees mirror end_date line.
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
  -- Case detection
  v_case            text;   -- 'correction' | 'prepend' | 'split' | 'gap_fill' | 'amendment'

  -- Slice rows
  v_target          employee_employment%ROWTYPE;
  v_first           employee_employment%ROWTYPE;
  v_current         employee_employment%ROWTYPE;

  -- Derived values
  v_designation     text;
  v_job_title       text;
  v_desig_label     text;
  v_work_country    text;
  v_currency_pl_id  uuid;
  v_currency_name   text;
  v_currency_id     uuid;
  v_manager_id      uuid;
  v_new_status      employee_status;
  v_existing_status employee_status;
  v_new_id          uuid;

  -- Manager cycle check
  v_check_id        uuid;
  v_cycle_chain     text[] := ARRAY[]::text[];
  v_location_parent text;

  -- Mirror sync helpers
  v_is_latest       boolean;
  v_new_manager_profile_id uuid;
  v_old_manager_id  uuid;

  -- DELETE_RECORD
  v_is_delete_record boolean;
  v_predecessor      employee_employment%ROWTYPE;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  IF NOT (
    user_can('employment', 'edit', p_employee_id)
    OR user_can('employment', 'bulk_import', NULL)
    OR EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = p_employee_id
        AND e.status IN ('Draft','Incomplete','Pending')
        AND e.deleted_at IS NULL
    )
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employment.edit')
    )
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id = p_employee_id
        AND wt.assigned_to = auth.uid()
        AND wt.status = 'pending'
    )
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id = p_employee_id
        AND wi.submitted_by = auth.uid()
        AND wi.status = 'awaiting_clarification'
    )
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
  -- NOTE: end_date validation removed (mig 485 — end_date column dropped)

  -- ── 3. DELETE_RECORD handling ──────────────────────────────────────────────
  v_is_delete_record := EXISTS (
    SELECT 1 FROM jsonb_each_text(p_proposed_data) v
    WHERE v.value = 'DELETE_RECORD'
  );

  IF v_is_delete_record THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id = p_employee_id AND effective_from = p_effective_from;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'DELETE_RECORD: no slice found at effective_from ' || p_effective_from::text);
    END IF;

    SELECT * INTO v_predecessor FROM employee_employment
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
    ORDER BY effective_from DESC LIMIT 1;

    IF FOUND THEN
      UPDATE employee_employment
      SET effective_to = v_target.effective_to, updated_at = NOW(), updated_by = auth.uid()
      WHERE id = v_predecessor.id;
    END IF;

    DELETE FROM employee_employment WHERE id = v_target.id;

    -- Mirror on delete only for Active/Inactive employees and if deleted slice was latest
    SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;
    IF v_existing_status IN ('Active', 'Inactive')
       AND NOT EXISTS (
         SELECT 1 FROM employee_employment
         WHERE employee_id = p_employee_id AND effective_from > p_effective_from
       ) AND FOUND THEN
      PERFORM set_config('prowess.allow_employment_sync', 'true', true);
      UPDATE employees
      SET designation      = v_predecessor.designation,
          job_title        = v_predecessor.job_title,
          dept_id          = v_predecessor.dept_id,
          manager_id       = v_predecessor.manager_id,
          hire_date        = v_predecessor.hire_date,
          work_country     = v_predecessor.work_country,
          work_location    = v_predecessor.work_location,
          base_currency_id = v_predecessor.base_currency_id,
          status           = v_predecessor.status,
          updated_at       = NOW()
      WHERE id = p_employee_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
  END IF;

  -- ── 4. Lock all slices for concurrent safety ───────────────────────────────
  PERFORM id FROM employee_employment
  WHERE employee_id = p_employee_id
  ORDER BY effective_from
  FOR UPDATE;

  -- ── 5. Case detection ──────────────────────────────────────────────────────

  -- 5a. Exact match → CORRECTION
  SELECT * INTO v_target FROM employee_employment
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN
    v_case := 'correction';
  END IF;

  -- 5b. Before all slices → PREPEND
  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_employment
    WHERE employee_id = p_employee_id
    ORDER BY effective_from ASC LIMIT 1;

    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case   := 'prepend';
      v_target := v_first;
    END IF;
  END IF;

  -- 5c. Inside a closed historical slice → SPLIT
  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id   = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  -- 5d. Open-ended slice exists → AMENDMENT (or GAP_FILL if none)
  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_employment
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true;
    IF FOUND THEN
      v_case   := 'amendment';
      v_target := v_current;
    ELSE
      v_case := 'gap_fill';
      SELECT * INTO v_target FROM employee_employment
      WHERE employee_id = p_employee_id
      ORDER BY effective_from DESC LIMIT 1;
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
        RETURN jsonb_build_object(
          'ok', false, 'error', 'CYCLE_DETECTED',
          'message', 'Assigning this manager would create a reporting cycle.',
          'chain', to_jsonb(v_cycle_chain)
        );
      END IF;
      v_cycle_chain := v_cycle_chain || v_check_id::text;
    END LOOP;
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

  -- ── 8. Derive fields (using v_target as COALESCE fallback) ────────────────
  SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;

  v_work_country := COALESCE(NULLIF(p_proposed_data->>'work_country', ''), v_target.work_country);

  SELECT (meta->>'currencyId')::uuid INTO v_currency_pl_id
  FROM picklist_values WHERE id = v_work_country::uuid;
  IF v_currency_pl_id IS NOT NULL THEN
    SELECT value INTO v_currency_name FROM picklist_values WHERE id = v_currency_pl_id;
  END IF;
  IF v_currency_name IS NOT NULL THEN
    SELECT id INTO v_currency_id FROM currencies WHERE name = v_currency_name AND active = true LIMIT 1;
  END IF;
  IF v_work_country IS NOT NULL AND v_currency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'CURRENCY_DERIVATION_FAILED', 'country', v_work_country);
  END IF;

  v_designation := COALESCE(NULLIF(p_proposed_data->>'designation', ''), v_target.designation);
  v_job_title   := NULLIF(p_proposed_data->>'job_title', '');
  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label FROM picklist_values WHERE id = v_designation::uuid;
    v_job_title := COALESCE(v_desig_label, v_target.job_title);
  ELSIF v_job_title IS NULL THEN
    v_job_title := v_target.job_title;
  END IF;

  v_new_status := COALESCE(
    NULLIF(p_proposed_data->>'status', '')::employee_status,
    v_target.status,
    v_existing_status,
    'Active'::employee_status
  );
  -- NOTE: end_date auto-inactivation removed (mig 485). Status must be set
  -- explicitly or via the Termination workflow (mig 482).

  -- ── 9. Execute by case ────────────────────────────────────────────────────

  IF v_case = 'correction' THEN
    UPDATE employee_employment SET
      designation      = v_designation,
      job_title        = v_job_title,
      dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
      manager_id       = COALESCE(v_manager_id, v_target.manager_id),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country     = v_work_country,
      work_location    = COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
      base_currency_id = COALESCE(v_currency_id, v_target.base_currency_id),
      status           = v_new_status,
      probation_end_date = COALESCE(
        NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_target.probation_end_date),
      updated_at       = NOW(),
      updated_by       = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, effective_from, effective_to, is_active,
      created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      v_work_country,
      COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id),
      v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_target.probation_end_date),
      p_effective_from,
      v_target.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    DECLARE v_inherited_end date := v_target.effective_to; BEGIN
      UPDATE employee_employment
      SET effective_to = p_effective_from - interval '1 day',
          updated_at   = NOW(), updated_by = auth.uid()
      WHERE id = v_target.id;

      INSERT INTO employee_employment (
        employee_id, designation, job_title, dept_id, manager_id,
        hire_date, work_country, work_location, base_currency_id,
        status, probation_end_date, effective_from, effective_to, is_active,
        created_by, updated_by
      ) VALUES (
        p_employee_id, v_designation, v_job_title,
        COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
        COALESCE(v_manager_id, v_target.manager_id),
        COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
        v_work_country,
        COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
        COALESCE(v_currency_id, v_target.base_currency_id),
        v_new_status,
        COALESCE(NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_target.probation_end_date),
        p_effective_from,
        v_inherited_end,
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
            is_active    = false,
            inactive_at  = NOW(),
            updated_at   = NOW(), updated_by = auth.uid()
        WHERE id = v_current.id;
      END IF;
    END IF;

    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, effective_from, effective_to, is_active,
      created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      v_work_country,
      COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id),
      v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_target.probation_end_date),
      p_effective_from, '9999-12-31'::date, true,
      auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 10. Mirror sync ────────────────────────────────────────────────────────
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_employment
    WHERE employee_id    = p_employee_id
      AND effective_from > p_effective_from
  );

  IF v_is_latest
     AND p_effective_from <= CURRENT_DATE
     AND v_existing_status IN ('Active', 'Inactive')
  THEN
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);

    v_old_manager_id := v_target.manager_id;

    UPDATE employees SET
      designation      = v_designation,
      job_title        = v_job_title,
      dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
      manager_id       = COALESCE(v_manager_id, v_target.manager_id),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country     = v_work_country,
      work_location    = COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
      base_currency_id = COALESCE(v_currency_id, v_target.base_currency_id),
      status           = v_new_status,
      updated_at       = NOW()
    WHERE id = p_employee_id;

    IF (COALESCE(v_manager_id, v_target.manager_id)) IS DISTINCT FROM v_old_manager_id THEN
      SELECT p.id INTO v_new_manager_profile_id
      FROM profiles p
      WHERE p.employee_id = COALESCE(v_manager_id, v_target.manager_id)
        AND p.is_active = true
      LIMIT 1;
      IF v_new_manager_profile_id IS NOT NULL THEN
        PERFORM sync_system_roles();
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'case', v_case, 'employment_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_employment_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_employment_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date) IS
  'Mig 453: full effective-dating rewrite (6-case logic). '
  'Mig 456: mirror guard — only syncs to employees base when status IN (Active, Inactive). '
  'Mig 460: active-only mirror guard re-applied on top of 453. '
  'Mig 485: end_date removed — column dropped; inactivation now via Termination workflow.';


-- =============================================================================
-- 2. _sync_employment_today — end_date removed from SELECT, drift check, UPDATE
--    Source: mig 459
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_employment_today(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
  v_new_manager_profile_id uuid;
BEGIN
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  FOR r IN
    SELECT
      ee.employee_id,
      ee.designation,
      ee.job_title,
      ee.dept_id,
      ee.manager_id,
      ee.hire_date,
      ee.work_country,
      ee.work_location,
      ee.base_currency_id,
      ee.status,
      e.manager_id AS old_manager_id
    FROM   employee_employment ee
    JOIN   employees e ON e.id = ee.employee_id
    WHERE  ee.effective_from <= p_as_of_date
      AND  ee.effective_to   >= p_as_of_date
      AND  ee.is_active       = true
      AND  e.deleted_at       IS NULL
      AND  e.status IN ('Active', 'Inactive')
      AND (
        e.designation      IS DISTINCT FROM ee.designation
        OR e.job_title     IS DISTINCT FROM ee.job_title
        OR e.dept_id       IS DISTINCT FROM ee.dept_id
        OR e.manager_id    IS DISTINCT FROM ee.manager_id
        OR e.hire_date     IS DISTINCT FROM ee.hire_date
        OR e.work_country  IS DISTINCT FROM ee.work_country
        OR e.work_location IS DISTINCT FROM ee.work_location
        OR e.base_currency_id IS DISTINCT FROM ee.base_currency_id
        OR e.status        IS DISTINCT FROM ee.status
      )
  LOOP
    BEGIN
      UPDATE employees
      SET
        designation      = r.designation,
        job_title        = r.job_title,
        dept_id          = r.dept_id,
        manager_id       = r.manager_id,
        hire_date        = r.hire_date,
        work_country     = r.work_country,
        work_location    = r.work_location,
        base_currency_id = r.base_currency_id,
        status           = r.status,
        updated_at       = now()
      WHERE id = r.employee_id;

      IF r.manager_id IS DISTINCT FROM r.old_manager_id AND r.manager_id IS NOT NULL THEN
        SELECT p.id INTO v_new_manager_profile_id
        FROM   profiles p
        WHERE  p.employee_id = r.manager_id
          AND  p.is_active   = true
        LIMIT  1;

        IF v_new_manager_profile_id IS NOT NULL THEN
          PERFORM sync_system_roles();
        END IF;
      END IF;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors    := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_employment_today(date) IS
  'Mig 353: initial creation. '
  'Mig 459: status IN (Active, Inactive) guard — excludes Draft/Pending. '
  'Mig 485: end_date removed from SELECT, drift check, and UPDATE — column dropped.';


-- =============================================================================
-- 3. wf_activate_employee — end_date removed from Step 4 mirror + fallback INSERT
--    Source: mig 458
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
  v_emp_sat       employee_employment%ROWTYPE;
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

    -- ── Step 4: Mirror satellite → employees base ──────────────────────────
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);
    UPDATE employees SET
      designation      = v_emp_sat.designation,
      job_title        = v_emp_sat.job_title,
      dept_id          = v_emp_sat.dept_id,
      manager_id       = v_emp_sat.manager_id,
      hire_date        = v_emp_sat.hire_date,
      work_country     = v_emp_sat.work_country,
      work_location    = v_emp_sat.work_location,
      base_currency_id = v_emp_sat.base_currency_id
      -- end_date removed (mig 485); status and updated_at already set in step 1
    WHERE id = p_employee_id;

  ELSE
    -- Fallback: no satellite slice — seed from employees base
    DECLARE
      v_emp employees%ROWTYPE;
    BEGIN
      SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;

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
      ON CONFLICT DO NOTHING;
    END;
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
  'Mig 458: mirrors satellite → employees on activation. '
  'Mig 485: end_date removed from Step 4 mirror and fallback INSERT.';


-- =============================================================================
-- 4. _bulk_export_employment — "End Date" column removed from both modes
--    Source: mig 451
-- =============================================================================

CREATE OR REPLACE FUNCTION _bulk_export_employment(
  p_include_inactive BOOLEAN,
  p_mode             TEXT
)
RETURNS SETOF JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id                                                          AS "Employee Code *",
        TO_CHAR(ee.effective_from, 'MM/DD/YYYY')                             AS "Effective Date *",
        TO_CHAR(ee.effective_to,   'MM/DD/YYYY')                             AS "Slice End",
        ee.is_active                                                          AS "Slice Is Active",
        pv_des.ref_id                                                         AS "Designation",
        ee.job_title                                                          AS "Job Title",
        d.dept_id                                                             AS "Department Code",
        mgr.employee_id                                                       AS "Manager Employee Code",
        TO_CHAR(ee.hire_date, 'MM/DD/YYYY')                                  AS "Hire Date",
        pv_wc.ref_id                                                          AS "Work Country (ISO3)",
        pv_loc.ref_id                                                         AS "Work Location",
        c.code                                                                AS "Base Currency",
        ee.status::text                                                       AS "Status",
        ee.id::text                                                           AS "id",
        TO_CHAR(ee.created_at,  'MM/DD/YYYY HH24:MI')                        AS "Created At",
        TO_CHAR(ee.updated_at,  'MM/DD/YYYY HH24:MI')                        AS "Updated At",
        TO_CHAR(ee.inactive_at, 'MM/DD/YYYY HH24:MI')                        AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e             ON e.id            = ee.employee_id
      LEFT JOIN departments d      ON d.id             = ee.dept_id
      LEFT JOIN employees mgr      ON mgr.id           = ee.manager_id
      LEFT JOIN currencies c       ON c.id             = ee.base_currency_id
      LEFT JOIN picklist_values pv_wc  ON pv_wc.id::text  = ee.work_country
      LEFT JOIN picklist_values pv_des ON pv_des.id::text = ee.designation
      LEFT JOIN picklist_values pv_loc ON pv_loc.id::text = ee.work_location
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ee.effective_from
    ) r;
  ELSE
    -- Current: open-ended active slice only
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id                                                          AS "Employee Code *",
        TO_CHAR(ee.effective_from, 'MM/DD/YYYY')                             AS "Effective Date *",
        pv_des.ref_id                                                         AS "Designation",
        ee.job_title                                                          AS "Job Title",
        d.dept_id                                                             AS "Department Code",
        mgr.employee_id                                                       AS "Manager Employee Code",
        TO_CHAR(ee.hire_date, 'MM/DD/YYYY')                                  AS "Hire Date",
        pv_wc.ref_id                                                          AS "Work Country (ISO3)",
        pv_loc.ref_id                                                         AS "Work Location",
        c.code                                                                AS "Base Currency",
        ee.status::text                                                       AS "Status",
        ee.id::text                                                           AS "id",
        TO_CHAR(ee.created_at,  'MM/DD/YYYY HH24:MI')                        AS "Created At",
        TO_CHAR(ee.updated_at,  'MM/DD/YYYY HH24:MI')                        AS "Updated At",
        TO_CHAR(ee.inactive_at, 'MM/DD/YYYY HH24:MI')                        AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e             ON e.id            = ee.employee_id
      LEFT JOIN departments d      ON d.id             = ee.dept_id
      LEFT JOIN employees mgr      ON mgr.id           = ee.manager_id
      LEFT JOIN currencies c       ON c.id             = ee.base_currency_id
      LEFT JOIN picklist_values pv_wc  ON pv_wc.id::text  = ee.work_country
      LEFT JOIN picklist_values pv_des ON pv_des.id::text = ee.designation
      LEFT JOIN picklist_values pv_loc ON pv_loc.id::text = ee.work_location
      WHERE ee.is_active = true
        AND ee.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id
    ) r;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION _bulk_export_employment(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_employment(boolean, text) IS
  'Mig 451: current mode now filters effective_to=9999-12-31. '
  'Mig 485: end_date column removed from both history and current SELECT lists.';


-- =============================================================================
-- 5. bulk_template_registry — remove "End Date" from employment schema_definition
-- =============================================================================

UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{columns}',
  (
    SELECT jsonb_agg(col)
    FROM jsonb_array_elements(schema_definition->'columns') AS col
    WHERE col->>'name' <> 'End Date'
  )
),
updated_at = NOW()
WHERE template_code = 'employment';


-- =============================================================================
-- 6. Drop vw_employment_drift (references both end_date columns) then recreate
--    without end_date. Must happen before the column drops below.
-- =============================================================================

DROP VIEW IF EXISTS vw_employment_drift;

CREATE OR REPLACE VIEW vw_employment_drift AS
SELECT
  e.id            AS employee_id,
  e.employee_id   AS employee_code,
  e.name,
  e.status        AS mirror_status,
  ee.status       AS sat_status,
  e.designation   AS mirror_designation,
  ee.designation  AS sat_designation,
  e.job_title     AS mirror_job_title,
  ee.job_title    AS sat_job_title,
  e.dept_id       AS mirror_dept_id,
  ee.dept_id      AS sat_dept_id,
  e.manager_id    AS mirror_manager_id,
  ee.manager_id   AS sat_manager_id,
  e.hire_date     AS mirror_hire_date,
  ee.hire_date    AS sat_hire_date,
  e.work_country  AS mirror_work_country,
  ee.work_country AS sat_work_country,
  e.work_location AS mirror_work_location,
  ee.work_location AS sat_work_location,
  e.base_currency_id AS mirror_base_currency_id,
  ee.base_currency_id AS sat_base_currency_id
FROM employees e
JOIN employee_employment ee
  ON  ee.employee_id = e.id
  AND ee.effective_to = '9999-12-31'::date
  AND ee.is_active    = true
WHERE
  e.status          IS DISTINCT FROM ee.status
  OR e.designation  IS DISTINCT FROM ee.designation
  OR e.job_title    IS DISTINCT FROM ee.job_title
  OR e.dept_id      IS DISTINCT FROM ee.dept_id
  OR e.manager_id   IS DISTINCT FROM ee.manager_id
  OR e.hire_date    IS DISTINCT FROM ee.hire_date
  OR e.work_country IS DISTINCT FROM ee.work_country
  OR e.work_location IS DISTINCT FROM ee.work_location
  OR e.base_currency_id IS DISTINCT FROM ee.base_currency_id;

COMMENT ON VIEW vw_employment_drift IS
  'Mig 351: initial creation. Mig 487: end_date columns removed (column dropped).';


-- =============================================================================
-- 7. Drop end_date from employee_employment
--    (notice_period_days already added by mig 483 — no column conflict)
-- =============================================================================

ALTER TABLE employee_employment
  DROP COLUMN IF EXISTS end_date;


-- =============================================================================
-- 8. Drop end_date from employees (mirror column)
-- =============================================================================

ALTER TABLE employees
  DROP COLUMN IF EXISTS end_date;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm column is gone from both tables
SELECT table_name, column_name
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   IN ('employee_employment', 'employees')
  AND  column_name  = 'end_date';
-- Expect: 0 rows

-- Confirm registry no longer has End Date column
SELECT elem->>'name' AS col_name
FROM   bulk_template_registry btr,
       jsonb_array_elements(schema_definition->'columns') AS elem
WHERE  template_code = 'employment'
  AND  elem->>'name' = 'End Date';
-- Expect: 0 rows

-- =============================================================================
-- END OF MIGRATION 485
-- =============================================================================
