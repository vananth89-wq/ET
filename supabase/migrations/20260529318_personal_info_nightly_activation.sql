-- =============================================================================
-- Migration 308 — activate_personal_info_records + pg_cron + drift view
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- When a future-dated personal info change is approved (or directly saved by an
-- admin), the new employee_personal slice is written with effective_from in the
-- future. upsert_personal_info() does NOT sync employees.name
-- for future-dated rows — it defers to this nightly job.
--
-- FUNCTION: activate_personal_info_records()
-- ──────────────────────────────────────────
-- Runs nightly (pg_cron at 00:05). Finds employee_personal rows whose
-- effective_from = CURRENT_DATE and syncs name to employees.
-- Sets prowess.allow_name_sync = 'true' to bypass the guard trigger.
-- Logs each run to job_run_log.
--
-- VIEW: vw_personal_name_drift
-- ────────────────────────────
-- Shows employees where employees.name differs from the
-- current employee_personal row. Zeroes = system is in sync.
-- Used by ops / admins to detect and fix drift.
-- =============================================================================


-- =============================================================================
-- 1. activate_personal_info_records()
-- =============================================================================

CREATE OR REPLACE FUNCTION activate_personal_info_records()
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

  -- Set session flag once — applies to all employee updates in this transaction
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  -- Find all personal_info rows whose effective window starts today
  FOR r IN
    SELECT
      ep.employee_id,
      ep.name
    FROM   employee_personal ep
    WHERE  ep.effective_from = CURRENT_DATE
      AND  ep.effective_to   = '9999-12-31'::date
      AND  ep.is_active      = true
  LOOP
    BEGIN
      UPDATE employees
      SET    name       = r.name,
             updated_at = now()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors     := v_errors + 1;
      v_error_text := COALESCE(v_error_text, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  -- Log to job_run_log
  INSERT INTO job_run_log (
    job_code,
    status,
    started_at,
    finished_at,
    rows_affected,
    error_message
  ) VALUES (
    'activate_personal_info_records',
    CASE WHEN v_errors = 0 THEN 'success' ELSE 'failed' END,
    v_job_start,
    clock_timestamp(),
    v_rows,
    v_error_text
  );

END;
$$;

COMMENT ON FUNCTION activate_personal_info_records() IS
  'Nightly pg_cron job (00:05). Finds employee_personal rows with effective_from = today '
  'and syncs name to employees. '
  'Sets prowess.allow_name_sync = ''true'' to bypass trg_guard_employee_name_sync. '
  'Logs each run to job_run_log (job_code = activate_personal_info_records). '
  'Monitor via: SELECT * FROM job_run_log WHERE job_code = ''activate_personal_info_records'' ORDER BY started_at DESC LIMIT 20. '
  'Mig 308: initial creation.';

-- No GRANT needed — called by pg_cron as superuser, not by authenticated users


-- =============================================================================
-- 2. Register pg_cron job
-- =============================================================================

-- Remove stale job if it exists from a previous attempt
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'activate_personal_info_records') THEN
    PERFORM cron.unschedule('activate_personal_info_records');
  END IF;
END;
$$;

SELECT cron.schedule(
  'activate_personal_info_records',   -- job name
  '5 0 * * *',                        -- 00:05 every day
  $$SELECT activate_personal_info_records()$$
);


-- =============================================================================
-- 3. vw_personal_name_drift — reconciliation view
-- =============================================================================

CREATE OR REPLACE VIEW vw_personal_name_drift AS
SELECT
  e.id                AS employee_id,
  e.employee_id       AS employee_number,
  e.status            AS employee_status,
  e.name              AS employees_name,
  ep.name             AS personal_name,
  ep.effective_from   AS personal_effective_from,
  ep.updated_at       AS personal_updated_at
FROM   employees e
JOIN   employee_personal ep
         ON  ep.employee_id  = e.id
         AND ep.effective_to = '9999-12-31'::date
         AND ep.is_active    = true
WHERE  e.deleted_at IS NULL
  AND  e.status     = 'Active'
  AND  e.name IS DISTINCT FROM ep.name;

COMMENT ON VIEW vw_personal_name_drift IS
  'Shows Active employees where employees.name differs from the '
  'current employee_personal row. Expected to be empty when the system is in sync. '
  'Populated by nightly job failures or direct writes to employees bypassing the guard. '
  'Query: SELECT * FROM vw_personal_name_drift; '
  'Fix drift by calling: SELECT upsert_personal_info(employee_id, ''{}''::jsonb, CURRENT_DATE) '
  'for each drifted row — this will sync employees from the personal_info row. '
  'Or run: SELECT activate_personal_info_records(); to re-run the sync for today''s rows. '
  'Mig 308: initial creation.';
