-- =============================================================================
-- Migration 620: fn_pre_insert_termination_slices + fn_revert — close instead of delete
--
-- Bug (mig 619): when the open-ended slice starts after LWD, fn_pre_insert
-- DELETEd it permanently. fn_revert cannot restore deleted slices, so after
-- a reversal the employee ends up with no open-ended active slice — leaving
-- them stuck (fn_pre_insert fails on re-termination: "No open-ended active
-- employment slice found").
--
-- Fix A — fn_pre_insert:
--   Instead of DELETE, set is_active = false on the post-LWD open slice.
--   This satisfies idx_ee_one_active_row (constraint only fires when
--   is_active = true AND effective_to = 9999-12-31), preserves the slice
--   for fn_revert to restore, and fn_finalize's existing DELETE
--   (effective_from > LWD+1 AND is_active = true) leaves it alone too.
--
-- Fix B — fn_revert_termination_execution:
--   After deleting the Inactive marker and reopening the slice closed at LWD,
--   also reactivate any closed post-LWD slices (is_active = false,
--   effective_from > LWD) that belong to the terminated employee.
--   These were closed by fn_pre_insert and must be restored on reversal.
-- =============================================================================


-- ── Fix A: fn_pre_insert_termination_slices ───────────────────────────────────

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

  v_lwd := COALESCE(v_term.last_working_date, v_term.separation_date);
  IF v_lwd IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No execution date: last_working_date and separation_date are both null');
  END IF;

  v_next_day := v_lwd + 1;

  -- Idempotency: Inactive slice at v_next_day already exists.
  IF EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from = v_next_day
      AND  status         = 'Inactive'
  ) THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'skipped', true,
      'reason',  'Inactive slice already exists',
      'lwd',     v_lwd
    );
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

  IF v_open_slice.effective_from <= v_lwd THEN
    -- Normal case: close the slice at LWD
    UPDATE employee_employment
    SET    effective_to = v_lwd,
           is_active    = false,
           inactive_at  = now(),
           inactive_by  = auth.uid(),
           updated_by   = auth.uid()
    WHERE  id = v_open_slice.id;
  ELSE
    -- Post-LWD slice: started after LWD (employment change made post-LWD).
    -- Set is_active = false so idx_ee_one_active_row allows the INSERT below.
    -- Do NOT delete — fn_revert must be able to restore it on reversal.
    UPDATE employee_employment
    SET    is_active   = false,
           inactive_at = now(),
           inactive_by = auth.uid(),
           updated_by  = auth.uid()
    WHERE  id = v_open_slice.id;
  END IF;

  -- Insert Inactive marker slice from LWD+1 → open-ended
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
    'ok',            true,
    'employee_id',   v_term.employee_id,
    'lwd',           v_lwd,
    'inactive_from', v_next_day
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_pre_insert_termination_slices(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_pre_insert_termination_slices(uuid) TO authenticated;

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 620 (Fix A): post-LWD open slice is closed with is_active=false instead '
  'of DELETE. This satisfies idx_ee_one_active_row and allows fn_revert to '
  'restore the slice on reversal (deleted slices cannot be restored).';


-- ── Fix B: fn_revert_termination_execution ────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_revert_termination_execution(
  p_reversal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reversal   RECORD;
  v_term       RECORD;
  v_lwd        date;
  v_next_day   date;
BEGIN
  SELECT * INTO v_reversal
  FROM   employee_termination_reversals
  WHERE  id = p_reversal_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reversal record not found: %', p_reversal_id;
  END IF;

  IF v_reversal.workflow_status <> 'APPROVED' THEN
    RAISE EXCEPTION 'Reversal is not APPROVED (status: %)', v_reversal.workflow_status;
  END IF;

  SELECT * INTO v_term
  FROM   employee_terminations
  WHERE  id = v_reversal.termination_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent termination not found for reversal %', p_reversal_id;
  END IF;

  v_lwd      := v_term.last_working_date;
  v_next_day := v_lwd + 1;

  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- Step 1: Delete the Inactive marker slice (effective_from = LWD+1, status=Inactive)
  DELETE FROM employee_employment
  WHERE  employee_id    = v_term.employee_id
    AND  effective_from = v_next_day
    AND  status         = 'Inactive';

  -- Step 2: Reopen the slice that was closed at LWD
  UPDATE employee_employment
  SET    effective_to = '9999-12-31'::date,
         is_active    = true,
         inactive_at  = NULL,
         inactive_by  = NULL,
         updated_by   = auth.uid()
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = v_lwd
    AND  is_active    = false;

  -- Step 3: Restore any post-LWD slices that fn_pre_insert closed (is_active=false)
  -- These are slices that started after LWD and were deactivated (not deleted)
  -- by fn_pre_insert mig 620 to satisfy idx_ee_one_active_row.
  -- Only restore if no open-ended active slice now exists (Step 2 may have created one).
  IF NOT EXISTS (
    SELECT 1 FROM employee_employment
    WHERE  employee_id  = v_term.employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    UPDATE employee_employment
    SET    is_active   = true,
           inactive_at = NULL,
           inactive_by = NULL,
           updated_by  = auth.uid()
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from > v_lwd
      AND  effective_to   = '9999-12-31'::date
      AND  is_active      = false;
  END IF;

  -- Step 4: Reactivate the employee
  UPDATE employees
  SET    status     = 'Active',
         updated_at = now()
  WHERE  id = v_term.employee_id;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION fn_revert_termination_execution(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_revert_termination_execution(uuid) TO authenticated;

COMMENT ON FUNCTION fn_revert_termination_execution(uuid) IS
  'Mig 620 (Fix B): Step 3 restores post-LWD slices that fn_pre_insert (mig 620) '
  'closed with is_active=false. Without this, reversals leave the employee with '
  'no open-ended active slice, breaking re-termination attempts.';
