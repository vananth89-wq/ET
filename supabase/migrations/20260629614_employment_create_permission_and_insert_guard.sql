-- =============================================================================
-- Migration 578 — employment.create permission + upsert_employment_info guard split
--
-- CHANGES
-- ───────
-- 1. Seed `employment.create` permission into the permissions table.
--    This causes the Permission Matrix UI to render a Create checkbox on the
--    Employment row (previously showed "—" because no row existed).
--
-- 2. Rewrite the access guard in upsert_employment_info so that:
--      CORRECTION case  (editing an existing slice in place)  → requires employment.edit
--      INSERT cases     (amendment / split / prepend / gap-fill) → requires employment.create
--
--    The guard is split into two layers:
--      Layer A (top of function, before case detection):
--        Allow if the caller has EITHER permission, OR is a hire-pipeline
--        actor, OR holds a workflow task. This lets the function proceed to
--        case detection before enforcing the fine-grained check.
--      Layer B (after case detection, before executing):
--        If v_case = 'correction'  → require employment.edit
--        If v_case IN insert cases → require employment.create
--        Bypass exceptions: bulk_import, hire-pipeline Draft/Incomplete/Pending,
--        workflow task holder, workflow submitter (awaiting_clarification) are
--        always allowed regardless of case — these are system paths.
-- =============================================================================

-- ── 1. Seed employment.create permission ─────────────────────────────────────

DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'employment';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'employment module not found — skipping employment.create seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description, sort_order)
  VALUES (
    'employment.create',
    v_module_id,
    'create',
    'Employment — Insert Slice',
    'Insert a new effective-dated employment record (amendment, split, prepend, or gap-fill). '
    'Controls the "Insert" button in the Employment history panel.',
    15   -- sits between view (10) and edit (20) in the matrix
  )
  ON CONFLICT (code) DO NOTHING;

  RAISE NOTICE 'employment.create permission seeded.';
END $$;

-- ── 2. Rewrite upsert_employment_info with split access guard ─────────────────

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

  -- Slice rows used as COALESCE fallback and for boundary operations
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
  v_end_date        date;
  v_new_status      employee_status;
  v_existing_status employee_status;
  v_new_id          uuid;

  -- Manager cycle check
  v_check_id        uuid;
  v_cycle_chain     text[] := ARRAY[]::text[];
  v_location_parent text;

  -- Mirror sync helpers
  v_is_latest              boolean;
  v_new_manager_profile_id uuid;
  v_old_manager_id         uuid;

  -- DELETE_RECORD
  v_is_delete_record boolean;
  v_predecessor      employee_employment%ROWTYPE;

  -- Access guard helpers
  v_is_system_path  boolean;  -- bulk / hire-pipeline / workflow actor bypass
BEGIN

  -- ── 1a. Layer-A access guard (coarse — either permission OR system path) ───
  --   Allows the function to proceed to case detection.
  --   Layer-B (below case detection) enforces the fine-grained edit vs create split.

  v_is_system_path := (
    user_can('employment', 'bulk_import', NULL)
    OR EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = p_employee_id
        AND e.status IN ('Draft','Incomplete','Pending')
        AND e.deleted_at IS NULL
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
  );

  IF NOT v_is_system_path THEN
    IF NOT (
      user_can('employment', 'edit',   p_employee_id)
      OR user_can('employment', 'create', p_employee_id)
      OR (
        p_employee_id = get_my_employee_id()
        AND (has_permission('employment.edit') OR has_permission('employment.create'))
      )
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: you do not have permission to edit employment information for this employee.');
    END IF;
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. DELETE_RECORD handling ──────────────────────────────────────────────
  v_is_delete_record := EXISTS (
    SELECT 1 FROM jsonb_each_text(p_proposed_data) v
    WHERE v.value = 'DELETE_RECORD'
  );

  IF v_is_delete_record THEN
    -- DELETE_RECORD requires edit permission (modifying existing data)
    IF NOT v_is_system_path AND NOT user_can('employment', 'edit', p_employee_id) THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: employment.edit permission required to delete an employment record.');
    END IF;

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

    IF NOT EXISTS (
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

  -- 5a. Exact match on any slice → CORRECTION
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

  -- 5d. Open-ended slice exists → AMENDMENT; otherwise GAP-FILL
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

  -- ── 1b. Layer-B access guard (fine-grained: edit vs create) ───────────────
  --   System paths (hire pipeline, workflow actors, bulk) bypass this check.
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      -- Editing an existing slice in place → requires employment.edit
      IF NOT (
        user_can('employment', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('employment.edit'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: employment.edit permission is required to edit an existing employment record.');
      END IF;
    ELSE
      -- Inserting a new slice → requires employment.create
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

  -- ── 9. Execute by case ────────────────────────────────────────────────────

  IF v_case = 'correction' THEN
    UPDATE employee_employment SET
      designation        = v_designation,
      job_title          = v_job_title,
      dept_id            = COALESCE(NULLIF(p_proposed_data->>'dept_id',       '')::uuid, v_target.dept_id),
      manager_id         = COALESCE(v_manager_id, v_target.manager_id),
      hire_date          = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country       = v_work_country,
      work_location      = COALESCE(NULLIF(p_proposed_data->>'work_location', '')::text, v_target.work_location),
      base_currency_id   = COALESCE(v_currency_id, v_target.base_currency_id),
      status             = v_new_status,
      probation_end_date = COALESCE(
        NULLIF(p_proposed_data->>'probation_end_date', '')::date, v_target.probation_end_date),
      notice_period_days = COALESCE(
        NULLIF(p_proposed_data->>'notice_period_days', '')::integer, v_target.notice_period_days),
      updated_at         = NOW(),
      updated_by         = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active,
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
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days', '')::integer, v_target.notice_period_days),
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
        status, probation_end_date, notice_period_days,
        effective_from, effective_to, is_active,
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
        COALESCE(NULLIF(p_proposed_data->>'notice_period_days', '')::integer, v_target.notice_period_days),
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
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active,
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
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days', '')::integer, v_target.notice_period_days),
      p_effective_from, '9999-12-31'::date, true,
      auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 10. Mirror sync — ONLY if this is the most recent slice ───────────────
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_employment
    WHERE employee_id    = p_employee_id
      AND effective_from > p_effective_from
  );

  IF v_is_latest AND p_effective_from <= CURRENT_DATE THEN
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
  'Mig 578: split access guard. CORRECTION (exact effective_from match) requires '
  'employment.edit. All insert cases (amendment/split/prepend/gap-fill) require '
  'employment.create. System paths (bulk, hire-pipeline, workflow actors) bypass '
  'the fine-grained check. employment.create permission seeded in this migration.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'employment.create') THEN
    RAISE EXCEPTION 'ABORT: employment.create permission not seeded.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'upsert_employment_info') THEN
    RAISE EXCEPTION 'ABORT: upsert_employment_info not found.';
  END IF;
  RAISE NOTICE 'Migration 578 verified: employment.create seeded, upsert_employment_info updated.';
END $$;
