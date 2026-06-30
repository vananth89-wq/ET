-- =============================================================================
-- Migration 619: fn_pre_insert_termination_slices — delete spurious post-LWD slices
--
-- Bug (mig 618): when the open-ended active slice starts AFTER LWD (employment
-- change was made post-LWD), mig 618 correctly skips the invalid close UPDATE
-- but still inserts the Inactive marker with is_active=true, effective_to=9999-12-31.
-- The existing post-LWD slice also has is_active=true, effective_to=9999-12-31,
-- so the INSERT hits idx_ee_one_active_row unique constraint → 400 error.
--
-- Fix: DELETE all active slices starting strictly after LWD before inserting
-- the Inactive marker. This removes the conflicting row and mirrors what
-- fn_finalize_termination_execution already does in its Step 1 cleanup.
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

  -- Close the open-ended slice at LWD ONLY if it starts on or before LWD.
  -- If it starts after LWD (employment change made post-LWD), skip the close.
  IF v_open_slice.effective_from <= v_lwd THEN
    UPDATE employee_employment
    SET    effective_to = v_lwd,
           is_active    = false,
           inactive_at  = now(),
           inactive_by  = auth.uid(),
           updated_by   = auth.uid()
    WHERE  id = v_open_slice.id;
  ELSE
    -- The open slice starts after LWD — it's spurious (created post-LWD).
    -- Delete ALL active slices starting after LWD so the Inactive marker
    -- INSERT doesn't hit idx_ee_one_active_row.
    -- fn_finalize does the same cleanup in its Step 1.
    DELETE FROM employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from >= v_next_day
      AND  is_active      = true;
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
  'Mig 619: when open slice starts after LWD, DELETE all active slices from '
  'LWD+1 onwards before inserting the Inactive marker — avoids '
  'idx_ee_one_active_row unique constraint violation. Mig 618 skipped the '
  'close UPDATE but forgot this pre-INSERT cleanup step.';
