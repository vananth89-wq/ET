-- =============================================================================
-- Migration 714 — Re-apply mig 681 verbatim and add ONLY the two new
--                 scheduling columns (work_schedule_id, holiday_calendar_id).
--
-- REASON FOR THIS MIGRATION
-- ═════════════════════════
-- Mig 713 was intended to teach upsert_employment_info about the two new
-- columns added by mig 703 (work_schedule_id, holiday_calendar_id).
-- Unfortunately mig 713 was written as a full rewrite based on an OLDER
-- template rather than as a targeted patch on mig 681. In doing so it
-- silently dropped 8 pieces of previously-working behaviour that had been
-- added incrementally over migs 632, 633, 634, 674 and 681:
--
--   1. auth.uid() IS NULL / prowess.trigger_context bypass  (from mig 681)
--   2. wi.record_id column name                              (from mig 681)
--   3. workflow_tasks + wt.assigned_to (correct table/col)   (from mig 681)
--   4. wi.submitted_by column name                           (from mig 681)
--   5. Draft/Incomplete/Pending hire bypass block            (from mig 674)
--   6. Section 6b — clear inherited inactive manager         (from mig 633)
--   7. Section 6c — clear inherited closed department        (from mig 634)
--   8. PERFORM set_config('prowess.allow_employment_sync')   (from mig 632)
--   9. `, 30` fallback on notice_period_days INSERT COALESCE (from mig 483)
--
-- The visible symptom was the hire wizard "Save Error" on notice_period_days
-- NOT NULL, but the other 7 dropped items are lurking regressions.
--
-- APPROACH — STRICTLY INCREMENTAL
-- ═══════════════════════════════
-- This migration re-issues upsert_employment_info with mig 681's body
-- VERBATIM, then adds ONLY the minimum lines needed to persist the two
-- new scheduling columns:
--
--   * Two DECLARE vars:                v_work_schedule_id, v_holiday_cal_id
--   * Two derive-field lines in §8:    read them from p_proposed_data
--   * Two lines in correction UPDATE:  work_schedule_id / holiday_calendar_id
--   * Two lines in each of the 3 INSERTs (prepend, split, amend/gap_fill)
--   * Two CASE clauses in propagation UPDATE
--   * NOTE: scheduling fields are NOT mirrored to the employees table
--     (they live only on the employment satellite).
--
-- Nothing else changes. Every guard, bypass, column name, cycle check,
-- currency derivation, mirror sync and error path is byte-for-byte identical
-- to mig 681.
--
-- Also re-issues get_employment_info_history to include the two new fields
-- (this part is identical to mig 713 — that function was purely additive).
--
-- Safe to run multiple times (CREATE OR REPLACE).
-- Supersedes: mig 713, mig 681.
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
  -- Mig 714: two new scheduling fields (columns added in mig 703)
  v_work_schedule_id uuid;
  v_holiday_cal_id   uuid;
BEGIN

  -- ── 1a. Layer-A: coarse access guard ──────────────────────────────────────
  -- Also bypass when called from the trigger (prowess.trigger_context)
  IF auth.uid() IS NULL
     OR current_setting('prowess.trigger_context', true) = 'true' THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path AND user_can('employment', 'bulk_import', NULL) THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path THEN
    -- FIX (a)(b): wi.record_id + workflow_tasks.assigned_to
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id   = p_employee_id
        AND wi.module_code IN ('employee_hire','employee_onboarding')
        AND wi.status      IN ('draft','pending','incomplete')
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id   = p_employee_id
        AND wt.assigned_to = auth.uid()
        AND wt.status      = 'pending'
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    -- FIX (c): wi.submitted_by (not wi.initiated_by)
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id    = p_employee_id
        AND wi.submitted_by = auth.uid()
        AND wi.status       = 'awaiting_clarification'
    ) THEN v_is_system_path := true; END IF;
  END IF;

  -- Draft/Incomplete/Pending hire bypass (mig 674 — preserved here)
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM employees
      WHERE id = p_employee_id
        AND status IN ('Draft', 'Incomplete', 'Pending')
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
     AND NULLIF(p_proposed_data->>'dept_id', '') IS NULL
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

  -- Mig 714: two new scheduling fields
  v_work_schedule_id := NULLIF(p_proposed_data->>'work_schedule_id',   '')::uuid;
  v_holiday_cal_id   := NULLIF(p_proposed_data->>'holiday_calendar_id','')::uuid;

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
      designation         = v_designation,
      job_title           = v_job_title,
      dept_id             = COALESCE(NULLIF(p_proposed_data->>'dept_id', '')::uuid, v_target.dept_id),
      manager_id          = COALESCE(v_manager_id, v_target.manager_id),
      hire_date           = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country        = v_work_country,
      work_location       = COALESCE(v_work_location, v_target.work_location),
      base_currency_id    = COALESCE(v_currency_id, v_target.base_currency_id),
      status              = v_new_status,
      probation_end_date  = COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      notice_period_days  = COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
      -- Mig 714: scheduling fields
      work_schedule_id    = COALESCE(v_work_schedule_id, v_target.work_schedule_id),
      holiday_calendar_id = COALESCE(v_holiday_cal_id,   v_target.holiday_calendar_id),
      updated_at          = NOW(), updated_by = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      work_schedule_id, holiday_calendar_id,               -- Mig 714
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
      COALESCE(v_work_schedule_id, v_target.work_schedule_id),   -- Mig 714
      COALESCE(v_holiday_cal_id,   v_target.holiday_calendar_id),-- Mig 714
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
        work_schedule_id, holiday_calendar_id,             -- Mig 714
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_designation, v_job_title,
        COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
        COALESCE(v_manager_id, v_target.manager_id),
        COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
        v_work_country, COALESCE(v_work_location, v_target.work_location),
        COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
        COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
        COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
        COALESCE(v_work_schedule_id, v_target.work_schedule_id),   -- Mig 714
        COALESCE(v_holiday_cal_id,   v_target.holiday_calendar_id),-- Mig 714
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
      work_schedule_id, holiday_calendar_id,               -- Mig 714
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
      COALESCE(v_work_schedule_id, v_target.work_schedule_id),   -- Mig 714
      COALESCE(v_holiday_cal_id,   v_target.holiday_calendar_id),-- Mig 714
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
      -- Mig 714: scheduling fields
      work_schedule_id = CASE
        WHEN (p_proposed_data ? 'work_schedule_id') AND NULLIF(p_proposed_data->>'work_schedule_id','') IS NOT NULL
        THEN v_work_schedule_id ELSE work_schedule_id END,
      holiday_calendar_id = CASE
        WHEN (p_proposed_data ? 'holiday_calendar_id') AND NULLIF(p_proposed_data->>'holiday_calendar_id','') IS NOT NULL
        THEN v_holiday_cal_id ELSE holiday_calendar_id END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 11. Sync employees head record ────────────────────────────────────────
  -- Scheduling fields (work_schedule_id, holiday_calendar_id) live ONLY on
  -- the employment satellite — they are NOT mirrored to the employees table.
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

REVOKE ALL    ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) TO authenticated;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) IS
  'Mig 714: mig 681 body verbatim + work_schedule_id / holiday_calendar_id '
  'handling. Restores 8 items dropped by mig 713 (trigger-context bypass, '
  'correct WF column names, Draft hire bypass, inactive-manager clear, '
  'closed-dept clear, allow_employment_sync bypass, notice_period_days=30 '
  'fallback in INSERTs).';


-- ── get_employment_info_history — additive: expose the two new columns ───────
-- (this section is identical to mig 713; the history RPC is purely additive
--  so no regression risk — but we re-issue it here for completeness).
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
      'id',                   ee.id,
      'employee_id',          ee.employee_id,
      'designation',          ee.designation,
      'job_title',            ee.job_title,
      'dept_id',              ee.dept_id,
      'manager_id',           ee.manager_id,
      'hire_date',            ee.hire_date,
      'work_country',         ee.work_country,
      'work_location',        ee.work_location,
      'base_currency_id',     ee.base_currency_id,
      'notice_period_days',   ee.notice_period_days,
      'status',               ee.status,
      'probation_end_date',   ee.probation_end_date,
      'work_schedule_id',     ee.work_schedule_id,
      'holiday_calendar_id',  ee.holiday_calendar_id,
      'effective_from',       ee.effective_from,
      'effective_to',         ee.effective_to,
      'is_active',            ee.is_active,
      'created_at',           ee.created_at,
      'created_by',           ee.created_by,
      'updated_at',           ee.updated_at,
      'updated_by',           ee.updated_by
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

REVOKE ALL     ON FUNCTION get_employment_info_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employment_info_history(uuid) TO authenticated;

COMMENT ON FUNCTION get_employment_info_history(uuid) IS
  'Mig 713/714: added work_schedule_id and holiday_calendar_id to returned fields.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'upsert_employment_info'
  ) THEN RAISE EXCEPTION 'ABORT: upsert_employment_info missing.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'get_employment_info_history'
  ) THEN RAISE EXCEPTION 'ABORT: get_employment_info_history missing.'; END IF;
  RAISE NOTICE 'Migration 714: mig 681 body + scheduling fields; all 8 regressed items restored.';
END;
$$;
