-- =============================================================================
-- Migration 353 — Shared effective-dated sync job
-- =============================================================================
--
-- Renames activate_personal_info_records → activate_effective_dated_records.
-- Extracts personal_info sync into _sync_personal_info_today().
-- Adds _sync_employment_today() for employment slices.
-- Adds _scan_end_date_inactive() for Part C §11.4 (future end_date scanner).
-- Single cron entry replaces the old one.
--
-- Design spec: §6 — docs/employment-effective-dating-design.md
-- Template:    mig 318 (activate_personal_info_records)
-- =============================================================================


-- =============================================================================
-- 1. Drop old cron entry and function
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'activate_personal_info_records') THEN
    PERFORM cron.unschedule('activate_personal_info_records');
  END IF;
END;
$$;

-- The mig 327 parameterized version also needs to be dropped before we replace
DROP FUNCTION IF EXISTS activate_personal_info_records(date);
DROP FUNCTION IF EXISTS activate_personal_info_records();


-- =============================================================================
-- 2. _sync_personal_info_today() — extracted from old activate_personal_info_records
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_personal_info_today(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
BEGIN
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  FOR r IN
    SELECT ep.employee_id, ep.name
    FROM   employee_personal ep
    WHERE  ep.effective_from <= p_as_of_date
      AND  ep.effective_to   >= p_as_of_date
      AND  ep.is_active       = true
      AND  EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id = ep.employee_id
          AND  e.name IS DISTINCT FROM ep.name
          AND  e.deleted_at IS NULL
      )
  LOOP
    BEGIN
      UPDATE employees
      SET    name       = r.name,
             updated_at = now()
      WHERE  id = r.employee_id;
      v_rows := v_rows + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors    := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_personal_info_today(date) IS
  'Internal helper: syncs employees.name from employee_personal for rows active on p_as_of_date. '
  'Called by activate_effective_dated_records(). '
  'Mig 353: extracted from activate_personal_info_records (mig 318/327).';


-- =============================================================================
-- 3. _sync_employment_today() — activate future-dated employment slices
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_employment_today(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
  v_new_manager_profile_id uuid;
BEGIN
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- Find employment slices whose effective window covers p_as_of_date
  -- and where the mirror on employees is out of date for any column
  FOR r IN
    SELECT
      ee.employee_id,
      ee.designation,
      ee.job_title,
      ee.dept_id,
      ee.manager_id,
      ee.hire_date,
      ee.end_date,
      ee.work_country,
      ee.work_location,
      ee.base_currency_id,
      ee.status,
      e.manager_id AS old_manager_id
    FROM   employee_employment ee
    JOIN   employees e ON e.id = ee.employee_id
    WHERE  ee.effective_from <= p_as_of_date
      AND  ee.effective_to   >= p_as_of_date
      AND  ee.is_active       = true
      AND  e.deleted_at       IS NULL
      AND (
        e.designation      IS DISTINCT FROM ee.designation
        OR e.job_title     IS DISTINCT FROM ee.job_title
        OR e.dept_id       IS DISTINCT FROM ee.dept_id
        OR e.manager_id    IS DISTINCT FROM ee.manager_id
        OR e.hire_date     IS DISTINCT FROM ee.hire_date
        OR e.end_date      IS DISTINCT FROM ee.end_date
        OR e.work_country  IS DISTINCT FROM ee.work_country
        OR e.work_location IS DISTINCT FROM ee.work_location
        OR e.base_currency_id IS DISTINCT FROM ee.base_currency_id
        OR e.status        IS DISTINCT FROM ee.status
      )
  LOOP
    BEGIN
      UPDATE employees
      SET
        designation      = r.designation,
        job_title        = r.job_title,
        dept_id          = r.dept_id,
        manager_id       = r.manager_id,
        hire_date        = r.hire_date,
        end_date         = r.end_date,
        work_country     = r.work_country,
        work_location    = r.work_location,
        base_currency_id = r.base_currency_id,
        status           = r.status,
        updated_at       = now()
      WHERE id = r.employee_id;

      -- Manager role sync if manager_id changed
      IF r.manager_id IS DISTINCT FROM r.old_manager_id AND r.manager_id IS NOT NULL THEN
        SELECT p.id INTO v_new_manager_profile_id
        FROM   profiles p
        WHERE  p.employee_id = r.manager_id
          AND  p.is_active   = true
        LIMIT  1;

        IF v_new_manager_profile_id IS NOT NULL THEN
          PERFORM sync_system_roles();
        END IF;
      END IF;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors    := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_employment_today(date) IS
  'Internal helper: syncs employees mirror columns from employee_employment for slices '
  'active on p_as_of_date. Detects and updates only employees with actual drift. '
  'Calls sync_system_roles() when manager_id changes. '
  'Called by activate_effective_dated_records(). '
  'Mig 353: initial creation.';


-- =============================================================================
-- 4. _scan_end_date_inactive() — Part C §11.4 end_date scanner
-- =============================================================================

CREATE OR REPLACE FUNCTION _scan_end_date_inactive()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
BEGIN
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- Find Active employees whose current end_date has come due
  FOR r IN
    SELECT
      e.id         AS employee_id,
      ee.id        AS slice_id
    FROM   employees e
    JOIN   employee_employment ee
      ON   ee.employee_id = e.id
      AND  ee.is_active   = true
      AND  ee.effective_to = '9999-12-31'::date
    WHERE  e.status   = 'Active'
      AND  e.end_date IS NOT NULL
      AND  e.end_date <= CURRENT_DATE
      AND  e.deleted_at IS NULL
  LOOP
    BEGIN
      -- Flip the satellite slice status in-place
      UPDATE employee_employment
      SET    status     = 'Inactive',
             updated_at = now()
      WHERE  id = r.slice_id;

      -- Flip the employees mirror — triggers sync_profile_on_employee_status
      UPDATE employees
      SET    status     = 'Inactive',
             updated_at = now()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors    := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _scan_end_date_inactive() IS
  'Internal helper: flips status → Inactive for Active employees whose end_date '
  'is today or in the past. Updates both employee_employment satellite and employees mirror. '
  'The mirror UPDATE fires sync_profile_on_employee_status → revokes roles. '
  'Part C §11.4 of the employment effective-dating design spec. '
  'Safe to re-run (idempotent — only touches Active rows with due end_date). '
  'Mig 353: initial creation.';


-- =============================================================================
-- 5. activate_effective_dated_records() — top-level cron wrapper
-- =============================================================================

CREATE OR REPLACE FUNCTION activate_effective_dated_records(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job_start  timestamptz := clock_timestamp();
  v_personal   jsonb;
  v_employment jsonb;
  v_end_date   jsonb;
  v_total_errors int;
BEGIN
  v_personal   := _sync_personal_info_today(p_as_of_date);
  v_employment := _sync_employment_today(p_as_of_date);
  v_end_date   := _scan_end_date_inactive();

  v_total_errors :=
    COALESCE((v_personal  ->>'error_count')::int, 0)
    + COALESCE((v_employment->>'error_count')::int, 0)
    + COALESCE((v_end_date ->>'error_count')::int, 0);

  INSERT INTO job_run_log (
    job_code, status, started_at, finished_at, rows_affected, error_message
  ) VALUES (
    'activate_effective_dated_records',
    CASE WHEN v_total_errors = 0 THEN 'success' ELSE 'partial' END,
    v_job_start,
    clock_timestamp(),
    COALESCE((v_personal->>'rows')::int, 0)
      + COALESCE((v_employment->>'rows')::int, 0)
      + COALESCE((v_end_date->>'rows')::int, 0),
    format(
      'personal: %s rows, employment: %s rows, end_date scan: %s flips | errors: %s',
      v_personal  ->>'rows',
      v_employment->>'rows',
      v_end_date  ->>'rows',
      v_total_errors
    )
  );
END;
$$;

COMMENT ON FUNCTION activate_effective_dated_records(date) IS
  'Nightly pg_cron job (00:05). Runs three passes: '
  '(1) _sync_personal_info_today — sync employees.name from employee_personal, '
  '(2) _sync_employment_today — sync 10 employment mirror columns from employee_employment, '
  '(3) _scan_end_date_inactive — flip status→Inactive for employees with due end_dates. '
  'One job_run_log row per run covering all three passes. '
  'Replaces activate_personal_info_records (mig 318/327). '
  'Mig 353: initial creation.';


-- =============================================================================
-- 6. Reschedule cron
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'activate_effective_dated_records') THEN
    PERFORM cron.unschedule('activate_effective_dated_records');
  END IF;
END;
$$;

SELECT cron.schedule(
  'activate_effective_dated_records',
  '5 0 * * *',
  $$SELECT activate_effective_dated_records()$$
);


-- =============================================================================
-- 7. Backward-compat alias — keep old function name callable for a transition period
-- =============================================================================
-- Any external callers (Jobs UI, runbooks, ops scripts) that still call
-- activate_personal_info_records() will now route through the new wrapper.

CREATE OR REPLACE FUNCTION activate_personal_info_records(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM activate_effective_dated_records(p_as_of_date);
END;
$$;

COMMENT ON FUNCTION activate_personal_info_records(date) IS
  'Backward-compat alias for activate_effective_dated_records(). '
  'Mig 353: thin wrapper; original implementation moved to activate_effective_dated_records.';
