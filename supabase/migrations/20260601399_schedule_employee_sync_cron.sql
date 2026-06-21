-- =============================================================================
-- Migration 378 — pg_cron schedule for activate_personal_info_records
-- =============================================================================
--
-- Registers a daily pg_cron job that runs activate_personal_info_records()
-- at 00:15 UTC every night.
--
-- Idempotent: unschedules first so re-running is always safe.
-- =============================================================================

DO $$
BEGIN

  -- Unschedule first (no-op if it doesn't exist)
  BEGIN
    PERFORM cron.unschedule('employee-sync');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'employee-sync',
    '15 0 * * *',                            -- daily at 00:15 UTC
    'SELECT activate_personal_info_records()'
  );
  RAISE NOTICE 'pg_cron: employee-sync scheduled (daily at 00:15 UTC)';

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron extension not available — schedule skipped. '
               'Enable pg_cron in Dashboard → Database → Extensions, then re-run this migration. '
               'Error: %', SQLERRM;
END;
$$;


-- Verify
SELECT jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'employee-sync';
