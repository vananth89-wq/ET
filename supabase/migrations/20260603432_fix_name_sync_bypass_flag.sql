-- =============================================================================
-- Migration 432 — Restore prowess.allow_name_sync bypass in upsert_personal_info
--                 and upsert_employee_master
-- =============================================================================
--
-- ROOT CAUSE
-- ──────────
-- trg_guard_employee_name_sync (mig 316) blocks direct UPDATE employees SET name
-- on Active employees unless the session-local flag
--   prowess.allow_name_sync = 'true'
-- is set in the same transaction. This is the correct design — employee_personal
-- is the source of truth; employees.name is a denormalised cache.
--
-- TWO REGRESSIONS:
--
-- 1. upsert_personal_info (mig 409 rewrite)
--    Mig 409 restored hire-pipeline Path B but accidentally dropped the
--      PERFORM set_config('prowess.allow_name_sync', 'true', true);
--    line that mig 379 and mig 380 both had correctly. Every bulk personal-info
--    import for Active employees now raises:
--      "Direct name updates on Active employees are blocked."
--
-- 2. upsert_employee_master (mig 376, design gap)
--    The ON CONFLICT DO UPDATE clause writes name = EXCLUDED.name directly
--    without setting the bypass flag. Same failure for any employee-master
--    bulk import that touches an Active employee's name.
--
-- FIX
-- ───
-- Add PERFORM set_config('prowess.allow_name_sync', 'true', true) immediately
-- before every UPDATE/INSERT that writes employees.name in both functions.
-- The flag is transaction-local (is_local = true) so it resets automatically
-- at the end of the transaction — no leakage to other connections or sessions.
--
-- BLAST-RADIUS AUDIT
-- ──────────────────
-- ✓ trg_guard_employee_name_sync — unchanged; still blocks all direct calls from
--   application code. Only these two SECURITY DEFINER RPCs set the flag.
-- ✓ upsert_personal_info — all existing paths (A/B/C/D/E), effective-dating
--   logic, overlap guard, and employee_personal insert are identical to mig 409.
--   Only the name-sync block gains the missing set_config call.
-- ✓ upsert_employee_master — all existing validation, department/manager
--   resolution, and status handling are unchanged. Only the INSERT adds the
--   set_config call before it.
-- ✓ No other code sets prowess.allow_name_sync — the flag remains exclusively
--   the contract of these two RPCs.
-- ✓ Hire wizard (Draft/Incomplete/Pending employees) — trigger passes through
--   for non-Active statuses; set_config call is harmless.
-- =============================================================================


-- ── Fix 1: upsert_personal_info ──────────────────────────────────────────────
-- Full function body preserved from mig 409. Only Step 8 (name sync) changes:
-- add PERFORM set_config(...) before UPDATE employees.

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
  v_current_row   employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_amendment  boolean;

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
  v_old_name      text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Path A: scoped HR — employee already in their target group
  -- Path B: hire pipeline — brand-new Draft employee not yet in target_group_members
  -- Path C: ESS self-edit
  -- Path D: approver holds a pending workflow task
  -- Path E: sent-back initiator
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR (
      user_can('personal_info', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = p_employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('personal_info.edit')
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
      'error', 'Access denied: you do not have permission to edit personal information for this employee.'
    );
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Fetch current open-ended row ───────────────────────────────────────

  SELECT * INTO v_current_row
  FROM   employee_personal
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 4. Overlap guard ──────────────────────────────────────────────────────

  IF EXISTS (
    SELECT 1
    FROM   employee_personal
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

  -- ── 5. Amendment: close or replace current open-ended row ─────────────────

  IF v_is_amendment THEN
    IF v_current_row.effective_from >= p_effective_from THEN
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSE
      UPDATE employee_personal
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 6. Compute name from first/middle/last ────────────────────────────────

  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   '')), '');

  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  -- ── 7. Insert new effective-dated slice ───────────────────────────────────

  INSERT INTO employee_personal (
    employee_id,
    first_name, middle_name, last_name, name,
    nationality, marital_status, gender, dob, photo_url,
    effective_from, effective_to, is_active,
    created_by, updated_by
  ) VALUES (
    p_employee_id,
    v_first_name,
    v_middle_name,
    v_last_name,
    v_computed_name,
    COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
    COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
    COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
    COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
    COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 8. Sync employees.name ────────────────────────────────────────────────
  -- FIX (mig 432): set_config bypass was present in mig 379/380 but dropped in
  -- the mig 409 rewrite. Restoring it here.
  -- The flag is transaction-local so it resets at end of transaction.

  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    SELECT name INTO v_old_name FROM employees WHERE id = p_employee_id;
    IF v_old_name IS DISTINCT FROM v_computed_name THEN
      PERFORM set_config('prowess.allow_name_sync', 'true', true);
      UPDATE employees SET name = v_computed_name, updated_at = now()
      WHERE  id = p_employee_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'personal_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Mig 432: restored set_config(allow_name_sync) bypass before employees.name sync. '
  'This was dropped in the mig 409 rewrite, causing bulk personal-info imports on '
  'Active employees to raise the name-guard trigger error. '
  'Mig 394 (409): restored hire pipeline Path B access guard.';


-- ── Fix 2: upsert_employee_master ────────────────────────────────────────────
-- Design gap (mig 376): ON CONFLICT DO UPDATE SET name = EXCLUDED.name ran
-- without the bypass flag. Add set_config before the INSERT so the flag is
-- active if the statement hits the ON CONFLICT UPDATE path.

CREATE OR REPLACE FUNCTION upsert_employee_master(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dept_id    UUID;
  v_manager_id UUID;
  v_status     employee_status;
BEGIN
  IF NOT user_can('employees', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: employees.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'employee_id', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_id (employee code) is required');
  END IF;
  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  -- Resolve department code → UUID
  IF NULLIF(p_row->>'department_code', '') IS NOT NULL THEN
    SELECT id INTO v_dept_id FROM departments WHERE dept_id = p_row->>'department_code' AND deleted_at IS NULL;
    IF v_dept_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Department code not found: %s', p_row->>'department_code'));
    END IF;
  END IF;

  -- Resolve manager employee_id code → UUID
  IF NULLIF(p_row->>'manager_employee_code', '') IS NOT NULL THEN
    SELECT id INTO v_manager_id FROM employees WHERE employee_id = p_row->>'manager_employee_code';
    IF v_manager_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Manager employee code not found: %s', p_row->>'manager_employee_code'));
    END IF;
  END IF;

  -- Parse status enum (default Active for new employees)
  IF NULLIF(p_row->>'status', '') IS NOT NULL THEN
    BEGIN
      v_status := (p_row->>'status')::employee_status;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Invalid status value: %s', p_row->>'status'));
    END;
  ELSE
    v_status := 'Active';
  END IF;

  -- FIX (mig 432): set bypass flag before INSERT so it is active if the statement
  -- hits the ON CONFLICT UPDATE path that writes employees.name.
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  INSERT INTO employees (employee_id, name, business_email, designation, job_title,
                         dept_id, manager_id, hire_date, end_date, status)
  VALUES (
    p_row->>'employee_id',
    p_row->>'name',
    NULLIF(p_row->>'business_email', ''),
    NULLIF(p_row->>'designation',    ''),
    NULLIF(p_row->>'job_title',      ''),
    v_dept_id,
    v_manager_id,
    NULLIF(p_row->>'hire_date', '')::date,
    NULLIF(p_row->>'end_date',  '')::date,
    v_status
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name           = EXCLUDED.name,
    business_email = COALESCE(NULLIF(EXCLUDED.business_email, ''), employees.business_email),
    designation    = COALESCE(NULLIF(EXCLUDED.designation,    ''), employees.designation),
    job_title      = COALESCE(NULLIF(EXCLUDED.job_title,      ''), employees.job_title),
    dept_id        = COALESCE(EXCLUDED.dept_id,    employees.dept_id),
    manager_id     = COALESCE(EXCLUDED.manager_id, employees.manager_id),
    hire_date      = COALESCE(EXCLUDED.hire_date,  employees.hire_date),
    end_date       = COALESCE(EXCLUDED.end_date,   employees.end_date),
    status         = EXCLUDED.status,
    updated_at     = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_employee_master IS
  'Bulk-import processor for employees (master) template. Upserts the employees table on employee_id code. Bypasses workflow. '
  'Mig 432: added set_config(allow_name_sync) bypass before INSERT to fix trigger block on Active employee name updates.';
GRANT EXECUTE ON FUNCTION upsert_employee_master(JSONB) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE 'Migration 432: upsert_personal_info and upsert_employee_master patched with allow_name_sync bypass.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 20260603432_fix_name_sync_bypass_flag.sql
-- =============================================================================
