-- =============================================================================
-- Migration 562 — 90-day retention policy for job_run_log
--
-- Registers a nightly pg_cron job that deletes job_run_log rows older than
-- 90 days. Runs at 02:30 UTC (after bulk_upload_job_retention at 02:00).
-- =============================================================================

SELECT cron.unschedule('job_run_log_retention')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'job_run_log_retention'
);

SELECT cron.schedule(
  'job_run_log_retention',
  '30 2 * * *',
  $$
    DELETE FROM public.job_run_log
    WHERE started_at < now() - interval '90 days';
  $$
);

-- Verify
SELECT jobname, schedule, active
FROM cron.job
WHERE jobname = 'job_run_log_retention';
