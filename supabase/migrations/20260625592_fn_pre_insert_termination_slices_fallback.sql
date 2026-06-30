-- =============================================================================
-- Migration 592: fn_pre_insert_termination_slices — fallback to latest closed slice
--
-- Bug: if a previous termination attempt (that was later withdrawn) already ran
-- the Edge Function and closed the open-ended Active employment slice, the next
-- legitimate approval finds no open-ended slice (effective_to = '9999-12-31')
-- and returns {ok: false} → Edge Function 400 → employment record not updated.
--
-- Fix: when no open-ended Active slice is found, fall back to the most recently
-- closed Active slice (highest effective_from). This lets the function still
-- insert the Inactive marker slice correctly. If the Inactive slice was already
-- inserted (idempotency check passes), it skips silently.
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
      'reason', 'Inactive slice already exists', 'lwd', v_lwd);
  END IF;

  -- Find current open-ended Active slice (normal path)
  SELECT * INTO v_open_slice
  FROM   employee_employment
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT  1;

  -- Fallback: a previous attempt may have already closed the slice (e.g. from a
  -- prior termination that was later withdrawn). Find the most recent closed
  -- Active slice to use as template for the Inactive marker insert.
  IF NOT FOUND THEN
    SELECT * INTO v_open_slice
    FROM   employee_employment
    WHERE  employee_id = v_term.employee_id
      AND  status      = 'Active'
    ORDER  BY effective_from DESC
    LIMIT  1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'No Active employment slice found for employee — cannot insert Inactive marker');
    END IF;

    -- Slice already closed — just insert the Inactive marker
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
      'inactive_from',  v_next_day,
      'note',           'slice was already closed by prior attempt; inserted Inactive marker only'
    );
  END IF;

  -- Normal path: open-ended slice found — close it, then insert Inactive marker

  -- Step 1: Close current slice at last_working_date
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         updated_at   = now()
  WHERE  id = v_open_slice.id;

  -- Step 2: Insert Inactive slice (effective_from = last_working_date + 1)
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

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 592: fallback to most-recent closed Active slice when no open-ended slice '
  'found — handles case where a prior (withdrawn) termination already closed the slice. '
  'Idempotency check (Inactive slice at LWD+1 already exists) unchanged.';
