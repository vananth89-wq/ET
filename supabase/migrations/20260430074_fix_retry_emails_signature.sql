-- =============================================================================
-- Migration 074: Fix wf_retry_failed_emails — add p_triggered_by parameter
--
-- JobsAdmin calls every job RPC with { p_triggered_by: uuid } for audit
-- logging, but wf_retry_failed_emails only accepted p_max_age_hours.
-- This caused: "Could not find the function public.wf_retry_failed_emails
-- (p_triggered_by) in the schema cache"
--
-- Fix: add p_triggered_by uuid DEFAULT NULL as a second parameter.
-- When provided (manual run from UI), the actor_id is written to
-- notification_attempts so the monitor shows who triggered the retry.
-- pg_cron calls wf_retry_failed_emails(24) — still works (positional).
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_retry_failed_emails(
  p_max_age_hours  integer DEFAULT 24,
  p_triggered_by   uuid    DEFAULT NULL   -- auth.uid() for manual runs; NULL = pg_cron
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
DECLARE
  v_functions_url  text;
  v_webhook_secret text;
  v_row            RECORD;
  v_attempt_num    integer;
  v_count          integer := 0;
BEGIN
  SELECT value INTO v_functions_url  FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_webhook_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_functions_url IS NULL OR v_functions_url = '' THEN
    RAISE NOTICE 'wf_retry_failed_emails: supabase_functions_url not configured';
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT n.id        AS notif_id,
           n.profile_id,
           n.title,
           n.body,
           n.link,
           q.id        AS queue_id
    FROM   notifications n
    LEFT   JOIN workflow_notification_queue q ON q.notification_id = n.id
    WHERE  n.email_status = 'failed'
      AND  n.created_at  >= now() - (p_max_age_hours || ' hours')::interval
    ORDER  BY n.created_at
    FOR UPDATE OF n SKIP LOCKED
  LOOP
    -- Reset email status so Edge Function can overwrite with result
    UPDATE notifications
    SET    email_status = 'pending',
           email_error  = NULL
    WHERE  id = v_row.notif_id;

    PERFORM net.http_post(
      url     := v_functions_url || '/send-notification-email',
      headers := jsonb_build_object(
                   'Content-Type',     'application/json',
                   'x-webhook-secret', COALESCE(v_webhook_secret, '')
                 ),
      body    := jsonb_build_object(
                   'notification_id', v_row.notif_id,
                   'profile_id',      v_row.profile_id,
                   'title',           v_row.title,
                   'body',            v_row.body,
                   'link',            v_row.link
                 )
    );

    -- Log attempt — actor_id = p_triggered_by (NULL when pg_cron)
    IF v_row.queue_id IS NOT NULL THEN
      SELECT COALESCE(MAX(attempt_number), 0) + 1
      INTO   v_attempt_num
      FROM   notification_attempts
      WHERE  queue_id = v_row.queue_id AND channel = 'email';

      INSERT INTO notification_attempts
        (queue_id, attempt_number, channel, status, actor_id)
      VALUES
        (v_row.queue_id, v_attempt_num, 'email', 'sent', p_triggered_by);
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_retry_failed_emails(integer, uuid) IS
  'Re-queues failed email notifications younger than p_max_age_hours (default 24). '
  'p_triggered_by: pass auth.uid() for manual runs (logged to notification_attempts); '
  'NULL = pg_cron / system auto-retry. Returns count of rows re-queued.';
