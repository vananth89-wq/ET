-- Migration 532: Termination slice RPCs — split slice insertion from status flip
--
-- Problem with current design:
--   apply-termination-approval did everything in the Edge Function (JS client):
--     1. Close current employment slice        — direct table UPDATE
--     2. Insert Inactive slice                 — direct table INSERT
--     3. Set employees.status = 'Inactive'     — BLOCKED by fn_guard_employee_employment_sync
--                                                (requires prowess.allow_employment_sync = true)
--     4. Stamp scheduled_executed = true
--   Steps 3 is broken for any actual execution (guard trigger blocks it).
--   All test cases were future-dated so the Edge Function exited early before step 3.
--
-- New split:
--   fn_pre_insert_termination_slices(p_termination_id)
--     — Called immediately on approval (regardless of date).
--     — Atomically closes current Active slice + inserts future Inactive slice.
--     — Does NOT touch employees.status (employee still Active and working).
--     — Idempotent: if Inactive slice already exists, returns {ok,skipped}.
--
--   fn_finalize_termination_execution(p_termination_id)
--     — Called by cron on/after last_working_date.
--     — Sets employees.status = 'Inactive' using allow_employment_sync bypass.
--     — Stamps scheduled_executed = true.
--     — Idempotent: if already stamped, returns {ok,skipped}.
--
--   fn_revert_termination_execution(p_reversal_id)
--     — Called by apply-termination-reversal Edge Function.
--     — Deletes Inactive slice, reopens Active slice.
--     — Only flips employees.status → 'Active' if scheduled_executed = true.
--     — Uses allow_employment_sync bypass for status flip.
--     — Idempotent.
--
-- The unique index idx_ee_one_active_row (one open-ended active row per employee)
-- is respected because the close + insert happen sequentially in the same
-- transaction inside these SECURITY DEFINER functions.

-- =============================================================================
-- 1. fn_pre_insert_termination_slices
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_pre_insert_termination_slices(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_term        RECORD;
  v_open_slice  RECORD;
  v_lwd         date;
  v_next_day    date;
BEGIN
  -- Load termination
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination not found');
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Termination is not APPROVED (status: %s)', v_term.workflow_status));
  END IF;

  -- Resolve anchor date
  v_lwd := COALESCE(v_term.last_working_date, v_term.separation_date);
  IF v_lwd IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No execution date: last_working_date and separation_date are both null');
  END IF;

  v_next_day := v_lwd + 1;

  -- Idempotency: if Inactive slice at v_next_day already exists, skip
  IF EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id   = v_term.employee_id
      AND  effective_from = v_next_day
      AND  status         = 'Inactive'
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', 'Inactive slice already exists');
  END IF;

  -- Find current open-ended Active slice
  SELECT * INTO v_open_slice
  FROM   employee_employment
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No open-ended active employment slice found for employee');
  END IF;

  -- Step 1: Close current slice at last_working_date
  -- (must happen before INSERT to avoid violating idx_ee_one_active_row)
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         updated_at   = now()
  WHERE  id = v_open_slice.id;

  -- Step 2: Insert future Inactive slice (effective_from = last_working_date + 1)
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
    notice_period_days,
    probation_end_date,
    status,
    effective_from,
    effective_to,
    is_active,
    created_by,
    updated_by
  ) VALUES (
    v_term.employee_id,
    v_open_slice.designation,
    v_open_slice.job_title,
    v_open_slice.dept_id,
    v_open_slice.manager_id,
    v_open_slice.hire_date,
    v_open_slice.work_country,
    v_open_slice.work_location,
    v_open_slice.base_currency_id,
    v_open_slice.notice_period_days,
    v_open_slice.probation_end_date,
    'Inactive',
    v_next_day,
    '9999-12-31'::date,
    true,
    v_open_slice.created_by,
    NULL
  );

  RETURN jsonb_build_object(
    'ok',             true,
    'employee_id',    v_term.employee_id,
    'lwd',            v_lwd,
    'inactive_from',  v_next_day
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_pre_insert_termination_slices(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_pre_insert_termination_slices(uuid) TO authenticated;

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 532: Atomically closes current employment slice at last_working_date and '
  'inserts a future Inactive slice (effective_from = last_working_date + 1). '
  'Called immediately on approval regardless of date. Does NOT touch employees.status. '
  'Idempotent — safe to call multiple times.';


-- =============================================================================
-- 2. fn_finalize_termination_execution
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_finalize_termination_execution(
  p_termination_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_term  RECORD;
  v_lwd   date;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = p_termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Termination not found');
  END IF;

  IF v_term.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Termination is not APPROVED (status: %s)', v_term.workflow_status));
  END IF;

  -- Idempotency
  IF v_term.scheduled_executed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', 'Already executed');
  END IF;

  v_lwd := COALESCE(v_term.last_working_date, v_term.separation_date);

  -- Guard: only execute on/after last_working_date
  IF v_lwd > v_today THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', format('Future-dated (lwd: %s)', v_lwd));
  END IF;

  -- Bypass the employment mirror guard for this transaction
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- Flip employees.status → Inactive (fires trg_sync_profile_on_employee_status
  -- which revokes roles and closes JR sets)
  UPDATE employees
  SET    status     = 'Inactive',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  -- Stamp execution
  UPDATE employee_terminations
  SET    scheduled_executed    = true,
         scheduled_executed_at = now(),
         updated_at            = now(),
         updated_by            = auth.uid()
  WHERE  id = p_termination_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'employee_id', v_term.employee_id,
    'executed_on', v_today
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_finalize_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_finalize_termination_execution(uuid) TO authenticated;

COMMENT ON FUNCTION fn_finalize_termination_execution(uuid) IS
  'Mig 532: Flips employees.status → Inactive and stamps scheduled_executed. '
  'Only executes when last_working_date <= today. Sets prowess.allow_employment_sync '
  'to bypass fn_guard_employee_employment_sync. Idempotent.';


-- =============================================================================
-- 3. fn_revert_termination_execution
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_revert_termination_execution(
  p_reversal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reversal  RECORD;
  v_term      RECORD;
  v_lwd       date;
  v_next_day  date;
BEGIN
  SELECT * INTO v_reversal
  FROM   employee_termination_reversals
  WHERE  id = p_reversal_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reversal not found');
  END IF;

  IF v_reversal.workflow_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Reversal is not APPROVED (status: %s)', v_reversal.workflow_status));
  END IF;

  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = v_reversal.termination_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Original termination not found');
  END IF;

  IF v_term.workflow_status <> 'REVERSED' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Original termination is not REVERSED (status: %s)', v_term.workflow_status));
  END IF;

  v_lwd      := COALESCE(v_term.last_working_date, v_term.separation_date);
  v_next_day := v_lwd + 1;

  -- Step 1: Delete the Inactive slice that was pre-inserted at approval
  DELETE FROM employee_employment
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from = v_next_day
    AND  status         = 'Inactive';

  -- Step 2: Reopen the prior Active slice (was closed at last_working_date)
  UPDATE employee_employment
  SET    effective_to = '9999-12-31'::date,
         is_active    = true,
         inactive_at  = NULL,
         updated_at   = now()
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = v_lwd;   -- was closed here by fn_pre_insert_termination_slices

  -- Step 3: Flip employees.status → Active ONLY if execution already ran
  -- (scheduled_executed = true means cron already set status → Inactive)
  IF v_term.scheduled_executed THEN
    PERFORM set_config('prowess.allow_employment_sync', 'true', true);

    UPDATE employees
    SET    status     = 'Active',
           updated_at = now()
    WHERE  id = v_term.employee_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',                 true,
    'employee_id',        v_term.employee_id,
    'status_flipped',     v_term.scheduled_executed,
    'lwd',                v_lwd
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_revert_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_revert_termination_execution(uuid) TO authenticated;

COMMENT ON FUNCTION fn_revert_termination_execution(uuid) IS
  'Mig 532: Reverts employment slice changes made by fn_pre_insert_termination_slices. '
  'Deletes Inactive slice, reopens Active slice. Flips employees.status → Active '
  'only if scheduled_executed = true (i.e. cron already ran). '
  'Sets prowess.allow_employment_sync bypass when needed. Idempotent.';
