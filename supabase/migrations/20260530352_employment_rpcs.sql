-- =============================================================================
-- Migration 352 — Employment info RPCs
-- =============================================================================
--
-- Three SECURITY DEFINER functions:
--
--   upsert_employment_info(p_employee_id, p_proposed_data, p_effective_from)
--     ├─ Access guard (HR / ESS-self / approver / sent-back)
--     ├─ Input validation (effective_from, end_date ≥ hire_date, dept exists,
--     │   work_location parent matches work_country)
--     ├─ Manager cycle check (up to 10 hops; CYCLE_DETECTED error)
--     ├─ Handles first insert and amendment (close + insert)
--     ├─ Carry-forward for unchanged fields
--     ├─ Auto-derives base_currency_id from work_country
--     ├─ Auto-populates job_title from DESIGNATION label when blank/unoverridden
--     ├─ Syncs employees mirror when effective_from ≤ today
--     ├─ Part B §11.4: flips status → Inactive when end_date ≤ today AND active
--     ├─ Calls sync_system_roles for new manager when manager_id changes
--     └─ Returns {ok, employment_info_id}
--
--   get_current_employment_info(p_employee_id)
--     └─ Returns the single active open-ended row as jsonb
--
--   get_employment_info_history(p_employee_id)
--     └─ Returns all rows ordered by effective_from DESC as jsonb
--
-- References: design spec §5, mig 317 (personal_info RPCs template)
-- =============================================================================


-- =============================================================================
-- 1. upsert_employment_info
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
      -- Hire pipeline: brand-new Draft employees aren't in target_group_members yet
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

  -- end_date must be ≥ hire_date if both provided
  IF (p_proposed_data->>'end_date') IS NOT NULL AND (p_proposed_data->>'hire_date') IS NOT NULL THEN
    IF (p_proposed_data->>'end_date')::date < (p_proposed_data->>'hire_date')::date THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date must be on or after hire_date.');
    END IF;
  END IF;

  -- dept_id must exist and not be soft-deleted
  IF (p_proposed_data->>'dept_id') IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM departments
      WHERE id = (p_proposed_data->>'dept_id')::uuid
        AND deleted_at IS NULL
    ) INTO v_dept_exists;
    IF NOT v_dept_exists THEN
      RETURN jsonb_build_object('ok', false, 'error', 'dept_id does not exist or has been deleted.');
    END IF;
  END IF;

  -- ── 3. Manager cycle check ────────────────────────────────────────────────

  v_manager_id := NULLIF(p_proposed_data->>'manager_id', '')::uuid;

  IF v_manager_id IS NOT NULL THEN

    -- Self-FK guard
    IF v_manager_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'An employee cannot be their own manager.');
    END IF;

    -- Walk the manager chain upward (up to 10 hops)
    v_check_id    := v_manager_id;
    v_cycle_chain := ARRAY[p_employee_id::text, v_manager_id::text];

    LOOP
      EXIT WHEN v_hops >= 10;
      v_hops := v_hops + 1;

      SELECT manager_id INTO v_check_id
      FROM   employees
      WHERE  id = v_check_id
        AND  deleted_at IS NULL;

      EXIT WHEN v_check_id IS NULL;

      v_cycle_chain := v_cycle_chain || v_check_id::text;

      IF v_check_id = p_employee_id THEN
        RETURN jsonb_build_object(
          'ok',     false,
          'error',  'CYCLE_DETECTED',
          'message', format(
            'Assigning this manager would create a reporting cycle.',
            v_manager_id
          ),
          'chain',  to_jsonb(v_cycle_chain)
        );
      END IF;
    END LOOP;
  END IF;

  -- ── 4. work_location parent validation ───────────────────────────────────
  -- Ensure work_location's parent picklist value matches the chosen work_country.
  IF (p_proposed_data->>'work_location') IS NOT NULL AND (p_proposed_data->>'work_country') IS NOT NULL THEN
    SELECT (parent_value_id)::text
    INTO   v_location_parent
    FROM   picklist_values
    WHERE  id = (p_proposed_data->>'work_location')::uuid;

    IF v_location_parent IS DISTINCT FROM (p_proposed_data->>'work_country') THEN
      RETURN jsonb_build_object(
        'ok',    false,
        'error', 'work_location does not belong to the selected work_country.'
      );
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

  -- ── 6. Overlap guard (against existing closed historical rows) ─────────────
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
      -- Mig 288 pattern: delete and replace
      DELETE FROM employee_employment
      WHERE  id = v_current_row.id;
    ELSE
      -- Standard close
      UPDATE employee_employment
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 8. Resolve derived fields ─────────────────────────────────────────────

  -- Carry forward work_country (proposed or current)
  v_work_country := COALESCE(
    NULLIF(p_proposed_data->>'work_country', ''),
    v_current_row.work_country
  );

  -- Auto-derive base_currency_id from work_country
  -- Step 1: CURRENCY picklist value UUID from country meta
  SELECT (meta->>'currencyId')::uuid
  INTO   v_currency_pl_id
  FROM   picklist_values
  WHERE  id = v_work_country::uuid;

  -- Step 2: Currency name from CURRENCY picklist value
  IF v_currency_pl_id IS NOT NULL THEN
    SELECT value INTO v_currency_name
    FROM   picklist_values
    WHERE  id = v_currency_pl_id;
  END IF;

  -- Step 3: currencies.id by name
  IF v_currency_name IS NOT NULL THEN
    SELECT id INTO v_currency_id
    FROM   currencies
    WHERE  name   = v_currency_name
      AND  active = true
    LIMIT  1;
  END IF;

  IF v_work_country IS NOT NULL AND v_currency_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'CURRENCY_DERIVATION_FAILED',
      'country', v_work_country
    );
  END IF;

  -- Designation and job_title auto-fill
  v_designation := COALESCE(
    NULLIF(p_proposed_data->>'designation', ''),
    v_current_row.designation
  );

  v_job_title := NULLIF(p_proposed_data->>'job_title', '');

  -- Auto-populate job_title from designation label when blank
  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label
    FROM   picklist_values
    WHERE  id = v_designation::uuid;

    v_job_title := COALESCE(v_desig_label, v_current_row.job_title);
  ELSIF v_job_title IS NULL THEN
    v_job_title := v_current_row.job_title;
  END IF;

  -- End-date and status for Part B §11.4
  v_end_date := COALESCE(
    NULLIF(p_proposed_data->>'end_date', '')::date,
    v_current_row.end_date
  );

  v_new_status := COALESCE(
    NULLIF(p_proposed_data->>'status', '')::employee_status,
    v_current_row.status
  );

  -- Part B: if end_date ≤ today AND currently Active → flip to Inactive in same slice
  IF v_end_date IS NOT NULL
     AND p_effective_from <= CURRENT_DATE
     AND v_end_date        <= CURRENT_DATE
     AND v_new_status       = 'Active'
  THEN
    v_new_status := 'Inactive';
  END IF;

  -- ── 9. Insert new slice ───────────────────────────────────────────────────

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
    probation_end_date,
    effective_from,
    effective_to,
    is_active,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    v_designation,
    v_job_title,
    COALESCE(NULLIF(p_proposed_data->>'dept_id',    '')::uuid, v_current_row.dept_id),
    COALESCE(v_manager_id, v_current_row.manager_id),
    COALESCE(NULLIF(p_proposed_data->>'hire_date',  '')::date, v_current_row.hire_date),
    v_end_date,
    v_work_country,
    COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_current_row.work_location),
    COALESCE(v_currency_id, v_current_row.base_currency_id),
    v_new_status,
    -- probation_end_date: use proposed value if provided, else carry forward
    COALESCE(NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_current_row.probation_end_date),
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 10. Mirror sync on employees when effective today or past ─────────────
  IF p_effective_from <= CURRENT_DATE THEN

    PERFORM set_config('prowess.allow_employment_sync', 'true', true);

    v_old_manager_id := v_current_row.manager_id;

    UPDATE employees
    SET
      designation      = v_designation,
      job_title        = v_job_title,
      dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id', '')::uuid,         v_current_row.dept_id),
      manager_id       = COALESCE(v_manager_id,                                          v_current_row.manager_id),
      hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date', '')::date,        v_current_row.hire_date),
      end_date         = v_end_date,
      work_country     = v_work_country,
      work_location    = COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text,    v_current_row.work_location),
      base_currency_id = COALESCE(v_currency_id,                                         v_current_row.base_currency_id),
      status           = v_new_status,
      updated_at       = now()
    WHERE id = p_employee_id;

    -- Manager role sync when manager_id changed
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

  -- ── 11. Return ────────────────────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',                  true,
    'employment_info_id',  v_new_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date) IS
  'Add a new effective-dated employment slice or amend the current open-ended slice. '
  'Validates access (HR / ESS-self / approver / sent-back). '
  'Checks manager cycle (up to 10 hops), dept existence, work_location parent match. '
  'Auto-derives base_currency_id from work_country; rejects if derivation fails. '
  'Auto-populates job_title from DESIGNATION picklist label when blank. '
  'Part B §11.4: flips status → Inactive when end_date ≤ today AND status = Active. '
  'Syncs employees mirror columns when effective_from ≤ CURRENT_DATE. '
  'Future-dated slices synced by nightly activate_effective_dated_records() job (mig 353). '
  'Returns {ok: true, employment_info_id} on success or {ok: false, error} on failure. '
  'Mig 352: initial creation.';

REVOKE ALL     ON FUNCTION upsert_employment_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_employment_info(uuid, jsonb, date) TO authenticated;


-- =============================================================================
-- 2. get_current_employment_info
-- =============================================================================

CREATE OR REPLACE FUNCTION get_current_employment_info(
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

  -- Access guard: same broad set as personal_info reads
  IF NOT (
    user_can('employment', 'view', p_employee_id)
    OR user_can('employment', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employment.view')
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
    -- Hire pipeline
    OR (
      user_can('employment',    'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  ) THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'id',                ee.id,
    'employee_id',       ee.employee_id,
    'designation',       ee.designation,
    'job_title',         ee.job_title,
    'dept_id',           ee.dept_id,
    'manager_id',        ee.manager_id,
    'hire_date',         ee.hire_date,
    'end_date',          ee.end_date,
    'work_country',      ee.work_country,
    'work_location',     ee.work_location,
    'base_currency_id',  ee.base_currency_id,
    'status',            ee.status,
    'probation_end_date', ee.probation_end_date,
    'effective_from',    ee.effective_from,
    'effective_to',      ee.effective_to,
    'is_active',         ee.is_active,
    'created_at',        ee.created_at,
    'created_by',        ee.created_by,
    'updated_at',        ee.updated_at,
    'updated_by',        ee.updated_by
  )
  INTO v_result
  FROM employee_employment ee
  WHERE ee.employee_id  = p_employee_id
    AND ee.effective_to = '9999-12-31'::date
    AND ee.is_active    = true;

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION get_current_employment_info(uuid) IS
  'Returns the single currently-active employment row for an employee as jsonb, '
  'or NULL if no active row exists or access is denied. '
  'Mig 352: initial creation.';

REVOKE ALL     ON FUNCTION get_current_employment_info(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_current_employment_info(uuid) TO authenticated;


-- =============================================================================
-- 3. get_employment_info_history
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

  -- Requires history or edit permission
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
      'id',                ee.id,
      'employee_id',       ee.employee_id,
      'designation',       ee.designation,
      'job_title',         ee.job_title,
      'dept_id',           ee.dept_id,
      'manager_id',        ee.manager_id,
      'hire_date',         ee.hire_date,
      'end_date',          ee.end_date,
      'work_country',      ee.work_country,
      'work_location',     ee.work_location,
      'base_currency_id',  ee.base_currency_id,
      'status',            ee.status,
      'probation_end_date', ee.probation_end_date,
      'effective_from',    ee.effective_from,
      'effective_to',      ee.effective_to,
      'is_active',         ee.is_active,
      'created_at',        ee.created_at,
      'created_by',        ee.created_by,
      'updated_at',        ee.updated_at,
      'updated_by',        ee.updated_by
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

COMMENT ON FUNCTION get_employment_info_history(uuid) IS
  'Returns all effective-dated employment rows for an employee, '
  'ordered by effective_from DESC (most recent first). '
  'Includes closed historical rows and the current open-ended row. '
  'Requires employment.history or employment.edit permission. '
  'Returns [] when access is denied. '
  'Mig 352: initial creation.';

REVOKE ALL     ON FUNCTION get_employment_info_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employment_info_history(uuid) TO authenticated;
