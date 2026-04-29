-- =============================================================================
-- Email Notifications via Supabase Edge Function + Resend
--
-- Hooks into the existing `notifications` table.  Every time a row is
-- INSERTed (by the workflow engine, SLA monitor, or any future source),
-- this trigger fires a non-blocking HTTP POST to the
-- `send-notification-email` Edge Function via pg_net.
--
-- The Edge Function looks up the recipient's email, renders an HTML template,
-- and sends via the Resend API.  Failures are logged but never propagate back
-- to the calling transaction (fire-and-forget).
--
-- Setup checklist (one-time, done in the Supabase Dashboard):
--
--   1. Enable the pg_net extension (Extensions tab — usually already on)
--
--   2. Set database config (run once, replace values):
--        ALTER DATABASE postgres
--          SET app.supabase_functions_url = 'https://<ref>.supabase.co/functions/v1';
--        ALTER DATABASE postgres
--          SET app.webhook_secret = '<your-random-secret-32-chars>';
--
--   3. Set Edge Function secrets (Supabase CLI or dashboard → Settings → Edge Functions):
--        supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx
--        supabase secrets set EMAIL_FROM="Expense Tracker <no-reply@yourco.com>"
--        supabase secrets set WEBHOOK_SECRET=<same-random-secret-as-above>
--        supabase secrets set APP_BASE_URL=https://yourapp.com
--
--   4. Deploy the Edge Function:
--        supabase functions deploy send-notification-email
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Enable pg_net (idempotent)
-- ════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Add email tracking columns to notifications
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS email_status  text        DEFAULT 'pending'
    CHECK (email_status IN ('pending','sent','failed','skipped')),
  ADD COLUMN IF NOT EXISTS email_sent_at timestamptz DEFAULT NULL;

COMMENT ON COLUMN notifications.email_status  IS 'Email delivery status: pending → sent|failed|skipped';
COMMENT ON COLUMN notifications.email_sent_at IS 'Timestamp when Resend confirmed the email was accepted';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Trigger function: fire-and-forget POST to Edge Function
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION trg_email_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_functions_url  text;
  v_webhook_secret text;
  v_payload        jsonb;
BEGIN
  -- Read configuration from app_config table
  SELECT value INTO v_functions_url  FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_webhook_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_functions_url IS NULL OR v_functions_url = '' THEN
    RAISE NOTICE 'trg_email_notification: supabase_functions_url not configured — skipping email for notification %', NEW.id;
    RETURN NEW;
  END IF;

  v_payload := jsonb_build_object(
    'notification_id', NEW.id,
    'profile_id',      NEW.profile_id,
    'title',           NEW.title,
    'body',            NEW.body,
    'link',            NEW.link
  );

  -- Fire non-blocking HTTP POST (pg_net queues it asynchronously)
  PERFORM extensions.http_post(
    url     := v_functions_url || '/send-notification-email',
    headers := jsonb_build_object(
                 'Content-Type',      'application/json',
                 'x-webhook-secret',  COALESCE(v_webhook_secret, '')
               ),
    body    := v_payload::text,
    timeout_milliseconds := 5000
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- Never let a missing pg_net or any error block the notification INSERT
  RAISE NOTICE 'trg_email_notification: error queuing email for notification % — %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION trg_email_notification() IS
  'Fires an async HTTP POST to the send-notification-email Edge Function '
  'for every new in-app notification row. Uses pg_net (fire-and-forget). '
  'Requires app.supabase_functions_url and app.webhook_secret to be set.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Attach trigger to notifications
-- ════════════════════════════════════════════════════════════════════════════

DROP TRIGGER IF EXISTS after_notification_insert_send_email ON notifications;

CREATE TRIGGER after_notification_insert_send_email
AFTER INSERT ON notifications
FOR EACH ROW
EXECUTE FUNCTION trg_email_notification();


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Index for email status monitoring (used by admin queries / job log)
-- ════════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS notifications_email_status_idx
  ON notifications (email_status, created_at DESC)
  WHERE email_status IN ('pending', 'failed');


-- ════════════════════════════════════════════════════════════════════════════
-- 6. Helper: retry failed emails (manual or via pg_cron)
--    Resets 'failed' rows that are younger than 24 h back to 'pending'
--    so the Edge Function re-processes them on next notification insert.
--    Call: SELECT wf_retry_failed_emails();
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_retry_failed_emails(
  p_max_age_hours integer DEFAULT 24
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_functions_url  text;
  v_webhook_secret text;
  v_row            RECORD;
  v_count          integer := 0;
BEGIN
  SELECT value INTO v_functions_url  FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_webhook_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_functions_url IS NULL OR v_functions_url = '' THEN
    RAISE NOTICE 'wf_retry_failed_emails: supabase_functions_url not configured';
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT id, profile_id, title, body, link
    FROM   notifications
    WHERE  email_status = 'failed'
      AND  created_at  >= now() - (p_max_age_hours || ' hours')::interval
    ORDER  BY created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Reset status so Edge Function will update it to 'sent' on success
    UPDATE notifications
    SET    email_status = 'pending'
    WHERE  id = v_row.id;

    PERFORM extensions.http_post(
      url     := v_functions_url || '/send-notification-email',
      headers := jsonb_build_object(
                   'Content-Type',     'application/json',
                   'x-webhook-secret', COALESCE(v_webhook_secret, '')
                 ),
      body    := jsonb_build_object(
                   'notification_id', v_row.id,
                   'profile_id',      v_row.profile_id,
                   'title',           v_row.title,
                   'body',            v_row.body,
                   'link',            v_row.link
                 )::text,
      timeout_milliseconds := 5000
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_retry_failed_emails(integer) IS
  'Re-queues failed email notifications younger than p_max_age_hours (default 24). '
  'Returns the number of rows re-queued. Safe to call multiple times.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm columns added
SELECT column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_name = 'notifications'
  AND  column_name IN ('email_status', 'email_sent_at')
ORDER  BY column_name;

-- Confirm trigger created
SELECT trigger_name, event_object_table, action_timing
FROM   information_schema.triggers
WHERE  trigger_name = 'after_notification_insert_send_email';

-- Confirm functions created
SELECT proname FROM pg_proc
WHERE  proname IN ('trg_email_notification', 'wf_retry_failed_emails');
