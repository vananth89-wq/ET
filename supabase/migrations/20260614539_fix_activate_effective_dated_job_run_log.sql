-- =============================================================================
-- Migration 539: Fix activate_effective_dated_records — job_run_log column names
--
-- The INSERT in mig 353 used non-existent columns:
--   finished_at  → should be completed_at
--   rows_affected → should be rows_processed
-- This caused the INSERT to fail, leaving no log rows in job_run_log,
-- so Background Jobs always showed "Never run".
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
  v_total_rows int;
  v_total_errors int;
BEGIN
  v_personal   := _sync_personal_info_today(p_as_of_date);
  v_employment := _sync_employment_today(p_as_of_date);
  v_end_date   := _scan_end_date_inactive();

  v_total_rows :=
    COALESCE((v_personal  ->>'rows')::int, 0)
    + COALESCE((v_employment->>'rows')::int, 0)
    + COALESCE((v_end_date ->>'rows')::int, 0);

  v_total_errors :=
    COALESCE((v_personal  ->>'error_count')::int, 0)
    + COALESCE((v_employment->>'error_count')::int, 0)
    + COALESCE((v_end_date ->>'error_count')::int, 0);

  INSERT INTO job_run_log (
    job_code, job_name, status,
    started_at, completed_at,
    rows_processed,
    summary,
    error_message
  ) VALUES (
    'activate_personal_info_records',
    'Employee Sync',
    CASE WHEN v_total_errors = 0 THEN 'success' ELSE 'partial' END,
    v_job_start,
    clock_timestamp(),
    v_total_rows,
    jsonb_build_object(
      'personal_rows',    COALESCE((v_personal  ->>'rows')::int, 0),
      'employment_rows',  COALESCE((v_employment->>'rows')::int, 0),
      'end_date_flips',   COALESCE((v_end_date  ->>'rows')::int, 0),
      'errors',           v_total_errors
    ),
    CASE WHEN v_total_errors > 0 THEN
      format('personal: %s rows, employment: %s rows, end_date: %s flips | errors: %s',
        v_personal  ->>'rows',
        v_employment->>'rows',
        v_end_date  ->>'rows',
        v_total_errors)
    ELSE NULL END
  );
END;
$$;

COMMENT ON FUNCTION activate_effective_dated_records(date) IS
  'Mig 539: fixed job_run_log INSERT (finished_at→completed_at, rows_affected→rows_processed). '
  'Writes job_code = activate_personal_info_records so Background Jobs UI matches.';

-- =============================================================================
-- END OF MIGRATION 539
-- =============================================================================
