-- =============================================================================
-- Migration 394 — 90-day retention policy for bulk_upload_job
--
-- 1. Enables pg_cron extension (idempotent).
-- 2. Schedules a nightly job at 02:00 UTC that:
--    a. Deletes bulk_upload_job rows older than 90 days.
--    b. Deletes matching error CSV files from the bulk-uploads Storage bucket
--       via the storage.objects table (Supabase manages the physical file via
--       its own storage trigger on that table).
-- =============================================================================

-- 1. Enable pg_cron (requires superuser; already enabled on Supabase projects)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 2. Remove any previous version of this job so re-running is idempotent
SELECT cron.unschedule('bulk_upload_job_retention')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'bulk_upload_job_retention'
);

-- 3. Schedule nightly cleanup at 02:00 UTC
SELECT cron.schedule(
  'bulk_upload_job_retention',
  '0 2 * * *',
  $$
    -- a. Delete Storage objects for jobs older than 90 days
    --    storage.objects rows have the path under the 'bulk-uploads' bucket.
    --    Deleting the row triggers Supabase Storage to remove the physical file.
    DELETE FROM storage.objects
    WHERE  bucket_id = 'bulk-uploads'
      AND  name IN (
             SELECT regexp_replace(storage_path, '^bulk-uploads/', '')
             FROM   public.bulk_upload_job
             WHERE  uploaded_at < now() - interval '90 days'
               AND  storage_path IS NOT NULL
             UNION
             SELECT regexp_replace(error_file_path, '^bulk-uploads/', '')
             FROM   public.bulk_upload_job
             WHERE  uploaded_at < now() - interval '90 days'
               AND  error_file_path IS NOT NULL
           );

    -- b. Delete the job rows themselves
    DELETE FROM public.bulk_upload_job
    WHERE  uploaded_at < now() - interval '90 days';
  $$
);

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT jobname, schedule, command
FROM   cron.job
WHERE  jobname = 'bulk_upload_job_retention';

-- =============================================================================
-- END OF MIGRATION 394
-- =============================================================================
