-- =============================================================================
-- Migration 560 — pg_cron schedule for process-scheduled-terminations
--
-- The Edge Function previously used Deno.cron which caused startup crashes.
-- This migration registers the same daily schedule via pg_cron + net.http_post,
-- consistent with other scheduled jobs in this project.
-- =============================================================================

-- Remove any previous registration (idempotent)
SELECT cron.unschedule('process_scheduled_terminations')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'process_scheduled_terminations'
);

-- Schedule daily at 00:05 UTC — reads functions URL from app_config
-- Uses x-service-role header which the Edge Function accepts without a JWT.
SELECT cron.schedule(
  'process_scheduled_terminations',
  '5 0 * * *',
  $cron$
    DO $$
    DECLARE
      v_url text;
    BEGIN
      SELECT value INTO v_url
      FROM   app_config
      WHERE  key = 'supabase_functions_url';

      IF v_url IS NULL OR v_url = '' THEN
        RAISE WARNING 'process_scheduled_terminations cron: supabase_functions_url not set in app_config';
        RETURN;
      END IF;

      PERFORM net.http_post(
        url     := v_url || '/process-scheduled-terminations',
        headers := jsonb_build_object(
          'Content-Type',   'application/json',
          'x-service-role', 'true'
        ),
        body    := '{}'::jsonb
      );
    END$$;
  $cron$
);

-- Verify
SELECT jobname, schedule, active
FROM cron.job
WHERE jobname = 'process_scheduled_terminations';
