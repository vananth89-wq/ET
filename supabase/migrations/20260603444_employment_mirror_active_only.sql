-- =============================================================================
-- Migration 444 — upsert_employment_info: only mirror to employees when Active
-- =============================================================================
--
-- PROBLEM
-- ───────
-- upsert_employment_info (step 10) runs:
--   UPDATE employees SET designation=..., dept_id=..., ..., updated_at=NOW()
-- on every call, even for Draft/Incomplete/Pending hires.
-- This stamps employees.updated_at every time employment data is saved during
-- the hire wizard, making the optimistic lock token stale on every autosave.
--
-- ROOT CAUSE ANALYSIS
-- ───────────────────
-- The mirror exists so employees base table stays in sync with the satellite
-- for queries that read designation/dept_id/hire_date directly from employees
-- (RLS, org chart, bulk exports). This is valid for Active employees.
-- For Draft/Incomplete/Pending hires it causes a side-effect (updated_at change)
-- with no benefit — nothing meaningful reads employment fields from the base
-- table for hire-pipeline records (they are not yet active employees).
--
-- FIX
-- ───
-- Guard step 10 with: only run the UPDATE employees mirror when the employee
-- is already Active (or Inactive). During hire pipeline, the satellite is the
-- sole source of truth. wf_activate_employee (mig 446) mirrors to employees
-- when the record is approved and activated.
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

  v_work_country    text;
  v_currency_pl_id  uuid;
  v_currency_name   text;
  v_currency_id     uuid;

  v_manager_id      uuid;
  v_check_id        uuid;
  v_hops            int := 0;
  v_cycle_chain     text[] := ARRAY[]::text[];

  v_designation     text;
  v_job_title       text;
  v_desig_label     text;

  v_end_date        date;
  v_new_status      employee_status;
  v_existing_status employee_status;

  v_new_manager_profile_id uuid;
  v_old_manager_id  uuid;

  v_dept_exists     boolean;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
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
      -- Approver inline edit — holds active pending task for this record
      EXISTS (
        SELECT 1
        FROM   workflow_tasks wt
        JOIN   workflow_instances wi ON wi.id = wt.instance_id
        WHERE  wi.record_id   = p_employee_id
          AND  wt.assigned_to = auth.uid()
          AND  wt.status      = 'pending'
      )
      AND user_can('hire_employee', 'edit_all_pending', NULL)
    )
    OR (
      -- Submitter re-editing after send-back (awaiting_clarification)
      EXISTS (
        SELECT 1
        FROM   workflow_instances wi
        WHERE  wi.record_id    = p_employee_id
          AND  wi.submitted_by = auth.uid()
          AND  wi.status       = 'awaiting_clarification'
      )
    )
    OR is_super_admin()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- ── 2. Department exists guard ─────────────────────────────────────────────
  IF p_proposed_data->>'dept_id' IS NOT NULL AND p_proposed_data->>'dept_id' != '' THEN
    SELECT EXISTS(SELECT 1 FROM departments WHERE id = (p_proposed_data->>'dept_id')::uuid)
      INTO v_dept_exists;
    IF NOT v_dept_exists THEN
      RETURN jsonb_build_object('ok', false, 'error', 'DEPT_NOT_FOUND');
    END IF;
  END IF;

  -- ── 3. Resolve work_country → base_currency ───────────────────────────────
  v_work_country := COALESCE(NULLIF(p_proposed_data->>'work_country', ''), NULL);

  IF v_work_country IS NOT NULL THEN
    SELECT (meta->>'currencyId')::uuid INTO v_currency_pl_id
    FROM   picklist_values WHERE id = v_work_country::uuid;

    IF v_currency_pl_id IS NULL THEN
      RETURN jsonb_build_object(
        'ok',     false,
        'error',  'CURRENCY_DERIVATION_FAILED',
        'country', v_work_country
      );
    END IF;

    SELECT id, name INTO v_currency_id, v_currency_name
    FROM   currencies WHERE picklist_value_id = v_currency_pl_id;

    IF v_currency_id IS NULL THEN
      RETURN jsonb_build_object(
        'ok',     false,
        'error',  'CURRENCY_DERIVATION_FAILED',
        'country', v_work_country
      );
    END IF;
  END IF;

  -- ── 4. Resolve manager (cycle guard) ─────────────────────────────────────
  IF p_proposed_data->>'manager_id' IS NOT NULL AND p_proposed_data->>'manager_id' != '' THEN
    v_manager_id  := (p_proposed_data->>'manager_id')::uuid;
    v_check_id    := v_manager_id;
    WHILE v_check_id IS NOT NULL AND v_hops < 20 LOOP
      v_cycle_chain := array_append(v_cycle_chain, v_check_id::text);
      IF v_check_id = p_employee_id THEN
        RETURN jsonb_build_object('ok', false, 'error', 'MANAGER_CYCLE_DETECTED');
      END IF;
      SELECT manager_id INTO v_check_id FROM employees WHERE id = v_check_id;
      v_hops := v_hops + 1;
    END LOOP;
  END IF;

  -- ── 5. Designation and job_title ──────────────────────────────────────────
  v_designation := NULLIF(p_proposed_data->>'designation', '');

  v_job_title := NULLIF(p_proposed_data->>'job_title', '');
  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label
    FROM   picklist_values WHERE id = v_designation::uuid;
    v_job_title := v_desig_label;
  END IF;

  -- ── 5b. Read current employees.status ─────────────────────────────────────
  SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;

  -- ── 6. Load current open-ended satellite row ──────────────────────────────
  SELECT * INTO v_current_row
  FROM   employee_employment
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 7. Overlap guard ──────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM employee_employment
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

  -- ── 8. Amendment: close or replace current row ────────────────────────────
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

  -- ── 9. Status derivation ──────────────────────────────────────────────────
  v_end_date := COALESCE(NULLIF(p_proposed_data->>'end_date', '')::date, v_current_row.end_date);
  v_new_status := CASE
    WHEN v_existing_status = 'Active'   THEN 'Active'::employee_status
    WHEN v_existing_status = 'Inactive' THEN 'Inactive'::employee_status
    ELSE COALESCE(v_current_row.status, v_existing_status, 'Draft'::employee_status)
  END;

  -- ── 10. Insert new satellite row ──────────────────────────────────────────
  INSERT INTO employee_employment (
    employee_id, designation, job_title, dept_id, manager_id,
    hire_date, end_date, work_country, work_location,
    base_currency_id, status, probation_end_date,
    effective_from, effective_to, is_active, created_by, updated_by
  ) VALUES (
    p_employee_id,
    v_designation,
    v_job_title,
    NULLIF(p_proposed_data->>'dept_id',        '')::uuid,
    v_manager_id,
    NULLIF(p_proposed_data->>'hire_date',       '')::date,
    v_end_date,
    v_work_country,
    NULLIF(p_proposed_data->>'work_location',   ''),
    v_currency_id,
    v_new_status,
    NULLIF(p_proposed_data->>'probation_end_date', '')::date,
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 11. Mirror sync — ACTIVE EMPLOYEES ONLY ───────────────────────────────
  -- During hire pipeline (Draft / Incomplete / Pending / Rejected), the
  -- satellite is the sole source of truth. The mirror runs when the employee
  -- is Active or Inactive — i.e., after approval via wf_activate_employee.
  -- This prevents upsert_employment_info from stamping employees.updated_at
  -- during autosaves, which was causing false-positive optimistic lock errors.
  IF p_effective_from <= CURRENT_DATE
     AND v_existing_status IN ('Active', 'Inactive')
  THEN

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
      status           = v_new_status
      -- updated_at intentionally omitted — trigger handles it, avoids invalidating optimistic lock
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
END;
$$;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date) IS
  'Writes an effective-dated employment record to employee_employment satellite. '
  'Mirrors employment fields to employees base table ONLY when status = Active/Inactive. '
  'During hire pipeline (Draft/Incomplete/Pending) the mirror is skipped — '
  'wf_activate_employee (mig 446) performs the one-time mirror on activation. '
  'Mig 444: hire-pipeline mirror removed to fix optimistic lock false positives.';
