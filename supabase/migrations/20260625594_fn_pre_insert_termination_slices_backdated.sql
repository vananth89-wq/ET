-- =============================================================================
-- Migration 594: fn_pre_insert_termination_slices — handle backdated terminations
--
-- Bug: for backdated terminations the open-ended Active slice may have an
-- effective_from AFTER the LWD (e.g. employee had a position change on Jun 25,
-- but LWD is Jun 5). Trying to close that slice by setting effective_to = Jun 5
-- violates chk_ee_effective_order (effective_from > effective_to).
--
-- Fix: detect the backdated case (open-ended slice starts after LWD) and:
--   1. DELETE all slices with effective_from > v_lwd (future slices cancelled
--      by the backdated termination — they never took effect for this employee).
--   2. Find the slice that was active ON v_lwd (effective_from <= v_lwd AND
--      effective_to >= v_lwd) and close it at v_lwd.
--   3. Insert the Inactive marker at v_next_day as usual.
--
-- Normal (non-backdated) case is unchanged.
-- Both paths guarded by the existing idempotency check.
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
  v_lwd_slice   RECORD;
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
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from = v_next_day
      AND  status         = 'Inactive'
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true,
      'reason', 'Inactive slice already exists', 'lwd', v_lwd);
  END IF;

  -- Find open-ended Active slice
  SELECT * INTO v_open_slice
  FROM   employee_employment
  WHERE  employee_id  = v_term.employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  LIMIT  1;

  -- ── BACKDATED TERMINATION ─────────────────────────────────────────────────
  -- The open-ended slice starts AFTER the LWD. Future slices must be removed
  -- (they never took effect for this terminated employee), and we close the
  -- slice that was actually active on the LWD.
  IF FOUND AND v_open_slice.effective_from > v_lwd THEN

    -- Step 1: Remove all slices with effective_from > v_lwd
    -- These are future slices that are cancelled by the backdated termination.
    DELETE FROM employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from > v_lwd;

    -- Step 2: Find the slice that was active on v_lwd
    SELECT * INTO v_lwd_slice
    FROM   employee_employment
    WHERE  employee_id    = v_term.employee_id
      AND  effective_from <= v_lwd
      AND  effective_to   >= v_lwd
    ORDER  BY effective_from DESC
    LIMIT  1;

    -- Step 3: Close it at v_lwd (only if effective_to > v_lwd)
    IF FOUND AND v_lwd_slice.effective_to > v_lwd THEN
      UPDATE employee_employment
      SET    effective_to = v_lwd,
             is_active    = false,
             inactive_at  = now(),
             updated_at   = now()
      WHERE  id = v_lwd_slice.id;
    END IF;
    -- If effective_to = v_lwd it's already closed on the right day — leave it.

    -- Step 4: Insert Inactive marker (use v_lwd_slice as template if found,
    -- else fall back to v_open_slice which we deleted)
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id, hire_date,
      work_country, work_location, base_currency_id, notice_period_days,
      probation_end_date, status, effective_from, effective_to, is_active,
      created_by, updated_by
    ) VALUES (
      v_term.employee_id,
      COALESCE(v_lwd_slice.designation,        v_open_slice.designation),
      COALESCE(v_lwd_slice.job_title,           v_open_slice.job_title),
      COALESCE(v_lwd_slice.dept_id,             v_open_slice.dept_id),
      COALESCE(v_lwd_slice.manager_id,          v_open_slice.manager_id),
      COALESCE(v_lwd_slice.hire_date,           v_open_slice.hire_date),
      COALESCE(v_lwd_slice.work_country,        v_open_slice.work_country),
      COALESCE(v_lwd_slice.work_location,       v_open_slice.work_location),
      COALESCE(v_lwd_slice.base_currency_id,    v_open_slice.base_currency_id),
      COALESCE(v_lwd_slice.notice_period_days,  v_open_slice.notice_period_days),
      COALESCE(v_lwd_slice.probation_end_date,  v_open_slice.probation_end_date),
      'Inactive',
      v_next_day,
      '9999-12-31'::date,
      true,
      COALESCE(v_lwd_slice.created_by, v_open_slice.created_by),
      NULL
    );

    RETURN jsonb_build_object(
      'ok',             true,
      'employee_id',    v_term.employee_id,
      'lwd',            v_lwd,
      'inactive_from',  v_next_day,
      'note',           'backdated termination: cancelled future slices, closed LWD slice'
    );
  END IF;

  -- ── NORMAL PATH (LWD >= open slice start) ────────────────────────────────

  -- Fallback: prior attempt may have closed the open-ended slice already
  IF NOT FOUND THEN
    SELECT * INTO v_open_slice
    FROM   employee_employment
    WHERE  employee_id = v_term.employee_id
      AND  status      = 'Active'
    ORDER  BY effective_from DESC
    LIMIT  1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'No Active employment slice found for employee');
    END IF;

    -- Slice already closed — just insert Inactive marker
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id, hire_date,
      work_country, work_location, base_currency_id, notice_period_days,
      probation_end_date, status, effective_from, effective_to, is_active,
      created_by, updated_by
    ) VALUES (
      v_term.employee_id,
      v_open_slice.designation, v_open_slice.job_title, v_open_slice.dept_id,
      v_open_slice.manager_id, v_open_slice.hire_date, v_open_slice.work_country,
      v_open_slice.work_location, v_open_slice.base_currency_id,
      v_open_slice.notice_period_days, v_open_slice.probation_end_date,
      'Inactive', v_next_day, '9999-12-31'::date, true, v_open_slice.created_by, NULL
    );

    RETURN jsonb_build_object(
      'ok', true, 'employee_id', v_term.employee_id,
      'lwd', v_lwd, 'inactive_from', v_next_day,
      'note', 'slice already closed by prior attempt; inserted Inactive marker only'
    );
  END IF;

  -- Normal: close open-ended slice, insert Inactive marker
  UPDATE employee_employment
  SET    effective_to = v_lwd,
         is_active    = false,
         inactive_at  = now(),
         updated_at   = now()
  WHERE  id = v_open_slice.id;

  INSERT INTO employee_employment (
    employee_id, designation, job_title, dept_id, manager_id, hire_date,
    work_country, work_location, base_currency_id, notice_period_days,
    probation_end_date, status, effective_from, effective_to, is_active,
    created_by, updated_by
  ) VALUES (
    v_term.employee_id,
    v_open_slice.designation, v_open_slice.job_title, v_open_slice.dept_id,
    v_open_slice.manager_id, v_open_slice.hire_date, v_open_slice.work_country,
    v_open_slice.work_location, v_open_slice.base_currency_id,
    v_open_slice.notice_period_days, v_open_slice.probation_end_date,
    'Inactive', v_next_day, '9999-12-31'::date, true, v_open_slice.created_by, NULL
  );

  RETURN jsonb_build_object(
    'ok', true, 'employee_id', v_term.employee_id,
    'lwd', v_lwd, 'inactive_from', v_next_day
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION fn_pre_insert_termination_slices(uuid) IS
  'Mig 594: handles backdated terminations where open-ended slice starts after LWD. '
  'Deletes post-LWD slices and closes the slice active on LWD instead. '
  'Mig 592 fallback (no open-ended slice) retained. Idempotency check unchanged.';
