-- =============================================================================
-- Migration 461 — Job relationship sync: immediate helper + nightly cron
--
-- WHAT
-- ────
-- 1. sync_job_relationship_mirrors(p_employee_id, p_set_id)
--    Immediate mirror: reads PM01–PM03, OM01–OM03 from a given set and writes
--    the 6 columns to employees base. Called inline by
--    fn_apply_job_relationship_set_transition when effective_from <= today.
--    (Referenced in mig 454 and 456_validate but never defined until now.)
--
-- 2. _sync_job_relationships_today(p_as_of_date)
--    Nightly helper: finds any employee whose open-ended job-relationship set
--    is effective on p_as_of_date and has drifted from the employees mirrors.
--    Analogous to _sync_employment_today (mig 353/459).
--
-- 3. activate_effective_dated_records updated to include job relationships
--    as pass 4. Nightly cron is unchanged (same schedule, same job name).
--
-- WHY IMMEDIATE SYNC
-- ──────────────────
-- When a user saves a job-relationship set with effective_from <= today,
-- fn_apply_job_relationship_set_transition calls sync_job_relationship_mirrors
-- right inside the same transaction — the employees mirror is current
-- immediately, with no wait for the nightly job.
--
-- WHY NIGHTLY SYNC
-- ────────────────
-- Future-dated saves (effective_from > today) are committed to the satellite
-- but not mirrored immediately. The nightly job picks them up when their
-- effective_from date arrives. Same pattern as employment.
-- =============================================================================


-- =============================================================================
-- 1. sync_job_relationship_mirrors — immediate mirror helper
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_job_relationship_mirrors(
  p_employee_id uuid,
  p_set_id      uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pm01 uuid; v_pm02 uuid; v_pm03 uuid;
  v_om01 uuid; v_om02 uuid; v_om03 uuid;
BEGIN
  -- Read the 6 relationship codes from the given set
  SELECT
    MAX(CASE WHEN relationship_code = 'PM01' THEN manager_employee_id END),
    MAX(CASE WHEN relationship_code = 'PM02' THEN manager_employee_id END),
    MAX(CASE WHEN relationship_code = 'PM03' THEN manager_employee_id END),
    MAX(CASE WHEN relationship_code = 'OM01' THEN manager_employee_id END),
    MAX(CASE WHEN relationship_code = 'OM02' THEN manager_employee_id END),
    MAX(CASE WHEN relationship_code = 'OM03' THEN manager_employee_id END)
  INTO v_pm01, v_pm02, v_pm03, v_om01, v_om02, v_om03
  FROM employee_job_relationship_item
  WHERE set_id = p_set_id;

  PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

  UPDATE employees
  SET    pm01_manager_id = v_pm01,
         pm02_manager_id = v_pm02,
         pm03_manager_id = v_pm03,
         om01_manager_id = v_om01,
         om02_manager_id = v_om02,
         om03_manager_id = v_om03,
         updated_at      = NOW()
  WHERE  id = p_employee_id;
END;
$$;

REVOKE ALL     ON FUNCTION sync_job_relationship_mirrors(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION sync_job_relationship_mirrors(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION sync_job_relationship_mirrors(uuid, uuid) IS
  'Immediate mirror: reads PM01–OM03 from the given set_id and writes the 6 '
  'pm/om manager_id columns to employees. Called by '
  'fn_apply_job_relationship_set_transition when effective_from <= today. '
  'Mig 461: initial definition (referenced in mig 454/456 but defined here).';


-- =============================================================================
-- 2. _sync_job_relationships_today — nightly helper
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_job_relationships_today(
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
  PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

  -- Find employees whose active job-relationship set covers p_as_of_date
  -- and whose mirror columns on employees are out of sync.
  -- Active/Inactive only — same guard as _sync_employment_today (mig 459).
  FOR r IN
    SELECT
      s.employee_id,
      s.id AS set_id,
      MAX(CASE WHEN i.relationship_code = 'PM01' THEN i.manager_employee_id END) AS pm01,
      MAX(CASE WHEN i.relationship_code = 'PM02' THEN i.manager_employee_id END) AS pm02,
      MAX(CASE WHEN i.relationship_code = 'PM03' THEN i.manager_employee_id END) AS pm03,
      MAX(CASE WHEN i.relationship_code = 'OM01' THEN i.manager_employee_id END) AS om01,
      MAX(CASE WHEN i.relationship_code = 'OM02' THEN i.manager_employee_id END) AS om02,
      MAX(CASE WHEN i.relationship_code = 'OM03' THEN i.manager_employee_id END) AS om03
    FROM   employee_job_relationship_set s
    LEFT JOIN employee_job_relationship_item i ON i.set_id = s.id
    JOIN   employees e ON e.id = s.employee_id
    WHERE  s.effective_from <= p_as_of_date
      AND  s.effective_to   >= p_as_of_date
      AND  s.is_active       = true
      AND  e.deleted_at      IS NULL
      AND  e.status IN ('Active', 'Inactive')
    GROUP BY s.employee_id, s.id
    HAVING (
      e.pm01_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'PM01' THEN i.manager_employee_id END)
      OR e.pm02_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'PM02' THEN i.manager_employee_id END)
      OR e.pm03_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'PM03' THEN i.manager_employee_id END)
      OR e.om01_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'OM01' THEN i.manager_employee_id END)
      OR e.om02_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'OM02' THEN i.manager_employee_id END)
      OR e.om03_manager_id IS DISTINCT FROM MAX(CASE WHEN i.relationship_code = 'OM03' THEN i.manager_employee_id END)
    )
  LOOP
    BEGIN
      UPDATE employees
      SET    pm01_manager_id = r.pm01,
             pm02_manager_id = r.pm02,
             pm03_manager_id = r.pm03,
             om01_manager_id = r.om01,
             om02_manager_id = r.om02,
             om03_manager_id = r.om03,
             updated_at      = NOW()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors     := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_job_relationships_today(date) IS
  'Nightly helper: syncs employees pm01–om03_manager_id columns from the active '
  'job-relationship set for p_as_of_date. Only Active/Inactive employees (same '
  'guard as _sync_employment_today). Called by activate_effective_dated_records(). '
  'Mig 461: initial creation.';


-- =============================================================================
-- 3. activate_effective_dated_records — add pass 4: job relationships
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
  v_job_start    timestamptz := clock_timestamp();
  v_personal     jsonb;
  v_employment   jsonb;
  v_end_date     jsonb;
  v_job_rel      jsonb;
  v_total_errors int;
BEGIN
  v_personal   := _sync_personal_info_today(p_as_of_date);
  v_employment := _sync_employment_today(p_as_of_date);
  v_end_date   := _scan_end_date_inactive();
  v_job_rel    := _sync_job_relationships_today(p_as_of_date);  -- pass 4 (mig 461)

  v_total_errors :=
    COALESCE((v_personal  ->>'error_count')::int, 0)
    + COALESCE((v_employment->>'error_count')::int, 0)
    + COALESCE((v_end_date ->>'error_count')::int, 0)
    + COALESCE((v_job_rel  ->>'error_count')::int, 0);

  INSERT INTO job_run_log (
    job_code, status, started_at, finished_at, rows_affected, error_message
  ) VALUES (
    'activate_effective_dated_records',
    CASE WHEN v_total_errors = 0 THEN 'success' ELSE 'partial' END,
    v_job_start,
    clock_timestamp(),
    COALESCE((v_personal  ->>'rows')::int, 0)
      + COALESCE((v_employment->>'rows')::int, 0)
      + COALESCE((v_end_date ->>'rows')::int, 0)
      + COALESCE((v_job_rel  ->>'rows')::int, 0),
    format(
      'personal: %s rows, employment: %s rows, end_date scan: %s flips, job_rel: %s rows | errors: %s',
      v_personal  ->>'rows',
      v_employment->>'rows',
      v_end_date  ->>'rows',
      v_job_rel   ->>'rows',
      v_total_errors
    )
  );
END;
$$;

COMMENT ON FUNCTION activate_effective_dated_records(date) IS
  'Nightly pg_cron job (00:05). Four passes: '
  '(1) _sync_personal_info_today — sync employees.name from employee_personal, '
  '(2) _sync_employment_today — sync 10 employment mirror columns (Active/Inactive only), '
  '(3) _scan_end_date_inactive — flip status→Inactive for due end_dates, '
  '(4) _sync_job_relationships_today — sync 6 pm/om columns from job-relationship satellite. '
  'One job_run_log row per run covering all four passes. '
  'Mig 353: initial (3 passes). Mig 461: added pass 4 (job relationships).';

DO $$
BEGIN
  RAISE NOTICE 'Migration 461: sync_job_relationship_mirrors defined. '
               '_sync_job_relationships_today added to nightly cron.';
END;
$$;
