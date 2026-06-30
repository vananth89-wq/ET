-- =============================================================================
-- Migration 618: fn_pre_insert_termination_slices — handle open slice after LWD
--
-- Bug: when an employment change was made AFTER the termination's LWD (e.g.,
-- LWD = 2026-06-04 but open-ended slice starts 2026-06-28), fn_pre_insert
-- tries to UPDATE effective_to = 2026-06-04 on that slice. This produces
-- effective_from (2026-06-28) > effective_to (2026-06-04) which violates a
-- check constraint → exception → wf_sync_module_status outer handler catches
-- it as WARNING → fn_finalize never called → scheduled_executed stays false.
--
-- Fix: if the open-ended slice starts AFTER the LWD, skip the close UPDATE.
-- fn_finalize already deletes spurious future slices (effective_from > LWD+1)
-- so they will be cleaned up in Phase 2.
--
-- If the open-ended slice starts ON or BEFORE the LWD, close it normally.
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
  -- If it starts after LWD (employment change made post-LWD), skip the close:
  -- fn_finalize will delete spurious future slices in Phase 2.
  IF v_open_slice.effective_from <= v_lwd THEN
    UPDATE employee_employment
    SET    effective_to = v_lwd,
           is_active    = false,
           inactive_at  = now(),
           inactive_by  = auth.uid(),
           updated_by   = auth.uid()
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
  'Mig 618: skip close UPDATE when open slice starts after LWD — prevents '
  'effective_from > effective_to constraint violation when employment changes '
  'were made after the termination LWD. fn_finalize deletes those spurious '
  'future slices in Phase 2.';
