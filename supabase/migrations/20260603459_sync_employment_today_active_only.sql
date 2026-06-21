-- =============================================================================
-- Migration 459 — _sync_employment_today: skip Draft/Pending employees
--
-- PROBLEM
-- ───────
-- _sync_employment_today (mig 353) mirrors employee_employment satellite →
-- employees base for ANY employee with drift — including Draft/Incomplete/
-- Pending/Rejected hire-pipeline records. It runs nightly at 00:05.
--
-- With mig 456, upsert_employment_info no longer mirrors to employees during
-- the hire pipeline. This creates drift intentionally — the satellite has the
-- values, employees base does not. But the nightly job detects this drift and
-- writes it back every night, stamping employees.updated_at = NOW().
--
-- This undoes mig 456 once per day: the optimistic lock token written during
-- a hire wizard session (which may span days for a long draft) would be
-- invalidated at midnight when the sync job runs.
--
-- FIX
-- ───
-- Add: AND e.status IN ('Active', 'Inactive') to the sync query.
-- Draft/Incomplete/Pending/Rejected employees are excluded entirely.
-- The satellite remains sole source of truth during the hire pipeline.
-- wf_activate_employee (mig 458) mirrors satellite → employees at activation.
-- After activation the employee is Active, so the nightly job will pick up
-- any subsequent drift normally.
--
-- ALSO
-- ────
-- The activate_effective_dated_records top-level wrapper is unchanged.
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
  -- and where the mirror on employees is out of date for any column.
  -- ACTIVE/INACTIVE ONLY (mig 459): Draft/Incomplete/Pending/Rejected employees
  -- are excluded — their satellite is authoritative and employees base is
  -- intentionally not mirrored during the hire pipeline (mig 456).
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
      AND  e.status IN ('Active', 'Inactive')    -- ← KEY GUARD (mig 459)
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
  'Mig 353: initial creation. '
  'Mig 459: added status IN (Active, Inactive) guard — excludes Draft/Pending records '
  'so the nightly job does not undo the mig 456 mirror suppression.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 459: _sync_employment_today updated — skips Draft/Pending employees.';
END;
$$;
