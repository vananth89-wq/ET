-- =============================================================================
-- Migration 327 — Parameterized personal info sync RPCs
-- =============================================================================
--
-- 1. activate_personal_info_records(p_as_of_date date DEFAULT CURRENT_DATE)
--    Adds an optional date parameter so the Jobs UI can run the sync for any
--    date, not just today. Existing pg_cron job calls it with no args
--    (defaults to CURRENT_DATE) — unchanged behaviour.
--
-- 2. sync_personal_info_for_employee(p_employee_id uuid, p_as_of_date date)
--    Syncs a single employee's employees.name from the employee_personal row
--    that was active on p_as_of_date. Useful for targeted remediation from
--    the Jobs UI without running the full batch sync.
--    Returns jsonb: { ok, synced, employee_name, personal_name, as_of_date }
-- =============================================================================


-- =============================================================================
-- 1. activate_personal_info_records — add p_as_of_date parameter
-- =============================================================================

CREATE OR REPLACE FUNCTION activate_personal_info_records(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job_start   timestamptz := clock_timestamp();
  v_rows        integer     := 0;
  v_errors      integer     := 0;
  v_error_text  text        := NULL;
  r             RECORD;
BEGIN

  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  -- Find Active employees where the personal_info row valid on p_as_of_date
  -- has a name that differs from employees.name.
  -- Covers: future-dated rows now valid, missed activations from past failures,
  -- and general drift from any source.
  FOR r IN
    SELECT
      ep.employee_id,
      ep.name AS personal_name
    FROM   employee_personal ep
    JOIN   employees e ON e.id = ep.employee_id
    WHERE  ep.effective_from <= p_as_of_date
      AND  ep.effective_to   >= p_as_of_date       -- row valid on target date
      AND  ep.is_active      = true
      AND  e.status          = 'Active'
      AND  e.deleted_at      IS NULL
      AND  e.name IS DISTINCT FROM ep.name          -- only sync where drift exists
  LOOP
    BEGIN
      UPDATE employees
      SET    name       = r.personal_name,
             updated_at = now()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors     := v_errors + 1;
      v_error_text := COALESCE(v_error_text, '')
                      || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  INSERT INTO job_run_log (
    job_code, status, started_at, finished_at, rows_affected, error_message
  ) VALUES (
    'activate_personal_info_records',
    CASE WHEN v_errors = 0 THEN 'success' ELSE 'failed' END,
    v_job_start, clock_timestamp(), v_rows, v_error_text
  );

END;
$$;

COMMENT ON FUNCTION activate_personal_info_records(date) IS
  'Batch sync: finds Active employees whose employees.name diverges from their '
  'employee_personal row active on p_as_of_date, and updates employees.name. '
  'Default: CURRENT_DATE (nightly pg_cron call). '
  'Pass a specific date from the Jobs UI to sync for any past or future date. '
  'Idempotent — only updates employees with actual drift. '
  'Mig 318: initial. Mig 326: drift-check fix. Mig 327: p_as_of_date param.';


-- =============================================================================
-- 2. sync_personal_info_for_employee — targeted single-employee sync
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_personal_info_for_employee(
  p_employee_id uuid,
  p_as_of_date  date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ep_row      employee_personal%ROWTYPE;
  v_emp_name    text;
  v_synced      boolean := false;
BEGIN

  -- Access guard: super admin or user with personal_info.edit on this employee
  IF NOT (
    is_super_admin()
    OR user_can('personal_info', 'edit', p_employee_id)
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'Access denied: personal_info.edit permission required.'
    );
  END IF;

  -- Find the employee_personal row active on p_as_of_date
  SELECT * INTO v_ep_row
  FROM   employee_personal
  WHERE  employee_id  = p_employee_id
    AND  effective_from <= p_as_of_date
    AND  effective_to   >= p_as_of_date
    AND  is_active      = true
  ORDER BY effective_from DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', format(
        'No active employee_personal record found for employee %s on %s.',
        p_employee_id, p_as_of_date
      )
    );
  END IF;

  -- Get current employees.name for comparison
  SELECT name INTO v_emp_name
  FROM   employees
  WHERE  id = p_employee_id;

  -- Only sync if there is actual drift
  IF v_emp_name IS NOT DISTINCT FROM v_ep_row.name THEN
    RETURN jsonb_build_object(
      'ok',           true,
      'synced',       false,
      'message',      'No drift detected — employees.name already matches employee_personal.',
      'employees_name',  v_emp_name,
      'personal_name',   v_ep_row.name,
      'as_of_date',      p_as_of_date
    );
  END IF;

  -- Sync
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  UPDATE employees
  SET    name       = v_ep_row.name,
         updated_at = now()
  WHERE  id = p_employee_id;

  v_synced := true;

  -- Log to job_run_log
  INSERT INTO job_run_log (
    job_code, status, started_at, finished_at, rows_affected, error_message
  ) VALUES (
    'sync_personal_info_for_employee',
    'success',
    clock_timestamp(), clock_timestamp(), 1, NULL
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'synced',          true,
    'employees_name',  v_emp_name,
    'personal_name',   v_ep_row.name,
    'effective_from',  v_ep_row.effective_from,
    'as_of_date',      p_as_of_date
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION sync_personal_info_for_employee(uuid, date) IS
  'Targeted sync: updates employees.name for a single employee from the '
  'employee_personal row active on p_as_of_date. '
  'Returns {ok, synced, employees_name, personal_name, effective_from, as_of_date}. '
  'synced=false when employees.name already matches (no-op, not an error). '
  'Logs each run to job_run_log. '
  'Access: personal_info.edit on the target employee OR super admin. '
  'Mig 327: initial creation.';

REVOKE ALL     ON FUNCTION sync_personal_info_for_employee(uuid, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION sync_personal_info_for_employee(uuid, date) TO authenticated;
