-- =============================================================================
-- Migration 052: Notification Delivery Monitor
--
-- Gaps fixed and new capabilities:
--   1.  app_config table — was referenced by trg_email_notification since
--       migration 035 but NEVER CREATED; every email has been silently
--       skipped since then.
--   2.  Extend workflow_notification_queue:
--         notification_id  — FK to the delivered notifications row (closes
--                            the audit loop so the monitor can join channels)
--         retry_count      — how many retries have been attempted
--         max_retries      — ceiling before forcing manual intervention
--   3.  Extend notifications:
--         email_error      — the Edge Function now writes back the failure
--                            reason so the monitor can surface it
--   4.  notification_attempts table — per-retry audit trail
--   5.  Update trg_wf_deliver_notification to capture RETURNING id and
--       write notification_id back to the queue row
--   6.  Update wf_deliver_pending_notifications likewise
--   7.  Update wf_retry_failed_emails to log retries to notification_attempts
--   8.  wf_retry_notification(queue_id, force) — admin single-row retry RPC
--       handles both in-app re-delivery and email re-fire in one call
--   9.  vw_notification_monitor — monitor screen data source
--  10.  pg_cron job — auto-retry failed emails every 15 minutes
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. app_config — global key/value configuration
--
-- Critical: trg_email_notification reads supabase_functions_url and
-- webhook_secret from this table. Without it every email is skipped.
-- Seeds placeholder values — ops must update them before emails go live.
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS app_config (
  key        text        PRIMARY KEY,
  value      text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Add description column if table already existed without it
ALTER TABLE app_config ADD COLUMN IF NOT EXISTS description text;

COMMENT ON TABLE app_config IS
  'Global key/value configuration read by trigger functions and Edge Functions. '
  'Rows are updated by ops — never by application code.';

-- Seed required keys (DO NOT OVERWRITE if already set)
INSERT INTO app_config (key, value, description) VALUES
  ('supabase_functions_url', '',
   'Base URL for Supabase Edge Functions, e.g. https://<ref>.supabase.co/functions/v1'),
  ('webhook_secret', '',
   'Shared HMAC secret between Postgres trigger and send-notification-email Edge Function')
ON CONFLICT (key) DO NOTHING;

-- Admin-only RLS: only service-role / SECURITY DEFINER functions read this
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_config_admin_select ON app_config;
CREATE POLICY app_config_admin_select ON app_config FOR SELECT
  USING (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Extend workflow_notification_queue
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_notification_queue
  ADD COLUMN IF NOT EXISTS notification_id uuid
    REFERENCES notifications(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS retry_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS max_retries integer NOT NULL DEFAULT 3;

COMMENT ON COLUMN workflow_notification_queue.notification_id IS
  'FK to the notifications row created on successful in-app delivery. '
  'NULL means in-app delivery has not yet succeeded.';
COMMENT ON COLUMN workflow_notification_queue.retry_count IS
  'Number of retry attempts made so far (not counting the initial delivery).';
COMMENT ON COLUMN workflow_notification_queue.max_retries IS
  'Maximum retries allowed before p_force must be used to override.';

CREATE INDEX IF NOT EXISTS wf_notif_queue_notification_id_idx
  ON workflow_notification_queue (notification_id)
  WHERE notification_id IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Extend notifications — email_error for failure diagnostics
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS email_error text DEFAULT NULL;

COMMENT ON COLUMN notifications.email_error IS
  'Error detail from the Resend API or Edge Function when email_status = ''failed''. '
  'Populated by the send-notification-email Edge Function.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. notification_attempts — per-retry audit trail
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS notification_attempts (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_id       uuid        NOT NULL
                             REFERENCES workflow_notification_queue(id) ON DELETE CASCADE,
  attempt_number integer     NOT NULL,
  channel        text        NOT NULL DEFAULT 'in_app'
                             CHECK (channel IN ('in_app', 'email')),
  status         text        NOT NULL
                             CHECK (status IN ('sent', 'failed')),
  error_message  text,
  attempted_at   timestamptz NOT NULL DEFAULT now(),
  actor_id       uuid        REFERENCES profiles(id) ON DELETE SET NULL
                             -- NULL = system / pg_cron auto-retry
);

COMMENT ON TABLE notification_attempts IS
  'Audit trail for every RETRY of a notification (not the initial delivery attempt). '
  'actor_id = NULL means the retry was triggered by the pg_cron job automatically.';

CREATE INDEX IF NOT EXISTS notif_attempts_queue_channel_idx
  ON notification_attempts (queue_id, channel, attempt_number);

ALTER TABLE notification_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notif_attempts_admin_select ON notification_attempts;
CREATE POLICY notif_attempts_admin_select ON notification_attempts FOR SELECT
  USING (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Update trg_wf_deliver_notification
--
-- Adds: RETURNING id INTO v_notif_id  and  notification_id = v_notif_id
-- so every successful delivery links the queue row to its notification.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION trg_wf_deliver_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tmpl     RECORD;
  v_title    text;
  v_body     text;
  v_key      text;
  v_val      text;
  v_link     text;
  v_notif_id uuid;
BEGIN
  -- Look up template
  SELECT title_tmpl, body_tmpl
  INTO   v_tmpl
  FROM   workflow_notification_templates
  WHERE  code = NEW.template_code;

  IF NOT FOUND THEN
    UPDATE workflow_notification_queue
    SET    status        = 'failed',
           error_message = 'notification template not found: ' || NEW.template_code,
           processed_at  = now()
    WHERE  id = NEW.id;
    RETURN NEW;
  END IF;

  v_title := v_tmpl.title_tmpl;
  v_body  := v_tmpl.body_tmpl;

  -- Replace {{key}} placeholders
  FOR v_key, v_val IN
    SELECT key, value FROM jsonb_each_text(NEW.payload)
  LOOP
    v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
    v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  -- Build deep-link
  SELECT CASE wi.module_code
    WHEN 'expense_reports' THEN '/expense/report/' || wi.record_id::text
    ELSE '/workflow/my-requests'
  END
  INTO   v_link
  FROM   workflow_instances wi
  WHERE  wi.id = NEW.instance_id;

  -- Deliver to in-app notifications — capture returned id
  INSERT INTO notifications (profile_id, title, body, link)
  VALUES (NEW.target_profile, v_title, v_body, COALESCE(v_link, '/workflow/my-requests'))
  RETURNING id INTO v_notif_id;

  -- Mark queue row sent and link to the delivered notification
  UPDATE workflow_notification_queue
  SET    status          = 'sent',
         processed_at    = now(),
         notification_id = v_notif_id
  WHERE  id = NEW.id;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  UPDATE workflow_notification_queue
  SET    status        = 'failed',
         error_message = SQLERRM,
         processed_at  = now()
  WHERE  id = NEW.id;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION trg_wf_deliver_notification() IS
  'Renders a workflow_notification_queue row using its template and payload, '
  'inserts into the notifications table, and links back via notification_id. '
  'Called by AFTER INSERT trigger on workflow_notification_queue.';


-- ════════════════════════════════════════════════════════════════════════════
-- 6. Update wf_deliver_pending_notifications
--    Same notification_id capture as the trigger above.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_deliver_pending_notifications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row      RECORD;
  v_tmpl     RECORD;
  v_title    text;
  v_body     text;
  v_key      text;
  v_val      text;
  v_link     text;
  v_notif_id uuid;
  v_count    integer := 0;
BEGIN
  FOR v_row IN
    SELECT * FROM workflow_notification_queue
    WHERE  status = 'pending'
    ORDER  BY created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      SELECT title_tmpl, body_tmpl
      INTO   v_tmpl
      FROM   workflow_notification_templates
      WHERE  code = v_row.template_code;

      IF NOT FOUND THEN
        UPDATE workflow_notification_queue
        SET    status        = 'failed',
               error_message = 'template not found: ' || v_row.template_code,
               processed_at  = now()
        WHERE  id = v_row.id;
        CONTINUE;
      END IF;

      v_title := v_tmpl.title_tmpl;
      v_body  := v_tmpl.body_tmpl;

      FOR v_key, v_val IN
        SELECT key, value FROM jsonb_each_text(v_row.payload)
      LOOP
        v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
        v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
      END LOOP;

      SELECT CASE wi.module_code
        WHEN 'expense_reports' THEN '/expense/report/' || wi.record_id::text
        ELSE '/workflow/my-requests'
      END
      INTO   v_link
      FROM   workflow_instances wi
      WHERE  wi.id = v_row.instance_id;

      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_row.target_profile, v_title, v_body, COALESCE(v_link, '/workflow/my-requests'))
      RETURNING id INTO v_notif_id;

      UPDATE workflow_notification_queue
      SET    status          = 'sent',
             processed_at    = now(),
             notification_id = v_notif_id
      WHERE  id = v_row.id;

      v_count := v_count + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE workflow_notification_queue
      SET    status        = 'failed',
             error_message = SQLERRM,
             processed_at  = now()
      WHERE  id = v_row.id;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_deliver_pending_notifications() IS
  'Processes all pending rows in workflow_notification_queue. '
  'Returns the number of notifications successfully delivered. '
  'Safe to call repeatedly — only touches status=''pending'' rows.';


-- ════════════════════════════════════════════════════════════════════════════
-- 7. Update wf_retry_failed_emails
--    Adds notification_attempts logging for the auto-retry job.
--    actor_id = NULL signals a system / pg_cron retry.
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

    PERFORM extensions.http_post(
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
                 )::text,
      timeout_milliseconds := 5000
    );

    -- Log attempt against the queue row (actor_id = NULL = system auto-retry)
    IF v_row.queue_id IS NOT NULL THEN
      SELECT COALESCE(MAX(attempt_number), 0) + 1
      INTO   v_attempt_num
      FROM   notification_attempts
      WHERE  queue_id = v_row.queue_id AND channel = 'email';

      INSERT INTO notification_attempts
        (queue_id, attempt_number, channel, status, actor_id)
      VALUES
        (v_row.queue_id, v_attempt_num, 'email', 'sent', NULL);
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_retry_failed_emails(integer) IS
  'Re-queues failed email notifications younger than p_max_age_hours (default 24). '
  'Logs each retry to notification_attempts (actor_id = NULL = pg_cron/auto). '
  'Returns the number of rows re-queued. Safe to call multiple times.';


-- ════════════════════════════════════════════════════════════════════════════
-- 8. wf_retry_notification — admin single-row retry
--
-- Determines what failed and handles both cases:
--   Case 1: inapp_status = 'failed'
--     → re-renders template, re-inserts into notifications (which auto-fires
--       the email trigger too), increments retry_count, logs attempt
--   Case 2: inapp_status = 'sent' AND email_status = 'failed'
--     → resets email_status to 'pending', re-fires Edge Function, logs attempt
--
-- p_force = true bypasses the max_retries ceiling.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_retry_notification(
  p_queue_id uuid,
  p_force    boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_queue          RECORD;
  v_notif          RECORD;
  v_tmpl           RECORD;
  v_title          text;
  v_body           text;
  v_key            text;
  v_val            text;
  v_link           text;
  v_notif_id       uuid;
  v_attempt_num    integer;
  v_email_status   text;
  v_functions_url  text;
  v_webhook_secret text;
BEGIN
  -- ── Access check ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_retry_notification: insufficient permissions';
  END IF;

  -- ── Load queue row ─────────────────────────────────────────────────────────
  SELECT *
  INTO   v_queue
  FROM   workflow_notification_queue
  WHERE  id = p_queue_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_retry_notification: queue row % not found', p_queue_id;
  END IF;

  -- ── Load notification (for email status) ───────────────────────────────────
  IF v_queue.notification_id IS NOT NULL THEN
    SELECT id, profile_id, title, body, link, email_status
    INTO   v_notif
    FROM   notifications
    WHERE  id = v_queue.notification_id;

    v_email_status := v_notif.email_status;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- Case 1: in-app delivery failed → re-deliver
  -- ════════════════════════════════════════════════════════════════════════════

  IF v_queue.status = 'failed' THEN

    IF NOT p_force AND v_queue.retry_count >= v_queue.max_retries THEN
      RAISE EXCEPTION
        'wf_retry_notification: max retries (%) reached for queue row % — pass p_force := true to override',
        v_queue.max_retries, p_queue_id;
    END IF;

    SELECT COALESCE(MAX(attempt_number), 0) + 1
    INTO   v_attempt_num
    FROM   notification_attempts
    WHERE  queue_id = p_queue_id AND channel = 'in_app';

    BEGIN
      -- Re-render template
      SELECT title_tmpl, body_tmpl
      INTO   v_tmpl
      FROM   workflow_notification_templates
      WHERE  code = v_queue.template_code;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'template not found: %', v_queue.template_code;
      END IF;

      v_title := v_tmpl.title_tmpl;
      v_body  := v_tmpl.body_tmpl;

      FOR v_key, v_val IN
        SELECT key, value FROM jsonb_each_text(v_queue.payload)
      LOOP
        v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
        v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
      END LOOP;

      SELECT CASE wi.module_code
        WHEN 'expense_reports' THEN '/expense/report/' || wi.record_id::text
        ELSE '/workflow/my-requests'
      END
      INTO   v_link
      FROM   workflow_instances wi
      WHERE  wi.id = v_queue.instance_id;

      -- Re-deliver (the after_notification_insert_send_email trigger fires
      -- automatically — email will be re-attempted for this new notification row)
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (v_queue.target_profile, v_title, v_body, COALESCE(v_link, '/workflow/my-requests'))
      RETURNING id INTO v_notif_id;

      UPDATE workflow_notification_queue
      SET    status          = 'sent',
             processed_at    = now(),
             notification_id = v_notif_id,
             retry_count     = retry_count + 1,
             error_message   = NULL
      WHERE  id = p_queue_id;

      INSERT INTO notification_attempts
        (queue_id, attempt_number, channel, status, actor_id)
      VALUES
        (p_queue_id, v_attempt_num, 'in_app', 'sent', auth.uid());

    EXCEPTION WHEN OTHERS THEN
      UPDATE workflow_notification_queue
      SET    retry_count   = retry_count + 1,
             error_message = SQLERRM
      WHERE  id = p_queue_id;

      INSERT INTO notification_attempts
        (queue_id, attempt_number, channel, status, error_message, actor_id)
      VALUES
        (p_queue_id, v_attempt_num, 'in_app', 'failed', SQLERRM, auth.uid());

      RAISE;
    END;

  -- ════════════════════════════════════════════════════════════════════════════
  -- Case 2: in-app OK, email failed → re-fire Edge Function
  -- ════════════════════════════════════════════════════════════════════════════

  ELSIF v_queue.status = 'sent' AND v_email_status = 'failed' THEN

    SELECT COALESCE(MAX(attempt_number), 0) + 1
    INTO   v_attempt_num
    FROM   notification_attempts
    WHERE  queue_id = p_queue_id AND channel = 'email';

    IF NOT p_force AND v_attempt_num > v_queue.max_retries THEN
      RAISE EXCEPTION
        'wf_retry_notification: max email retries (%) reached — pass p_force := true to override',
        v_queue.max_retries;
    END IF;

    SELECT value INTO v_functions_url  FROM app_config WHERE key = 'supabase_functions_url';
    SELECT value INTO v_webhook_secret FROM app_config WHERE key = 'webhook_secret';

    IF v_functions_url IS NULL OR v_functions_url = '' THEN
      RAISE EXCEPTION 'wf_retry_notification: supabase_functions_url not configured in app_config';
    END IF;

    -- Reset email status so Edge Function can write back the new result
    UPDATE notifications
    SET    email_status = 'pending',
           email_error  = NULL
    WHERE  id = v_notif.id;

    -- Re-fire Edge Function (pg_net: fire-and-forget)
    PERFORM extensions.http_post(
      url     := v_functions_url || '/send-notification-email',
      headers := jsonb_build_object(
                   'Content-Type',     'application/json',
                   'x-webhook-secret', COALESCE(v_webhook_secret, '')
                 ),
      body    := jsonb_build_object(
                   'notification_id', v_notif.id,
                   'profile_id',      v_notif.profile_id,
                   'title',           v_notif.title,
                   'body',            v_notif.body,
                   'link',            v_notif.link
                 )::text,
      timeout_milliseconds := 5000
    );

    -- Log attempt optimistically (pg_net is fire-and-forget; Edge Function
    -- updates email_status to 'sent'/'failed' when it completes)
    INSERT INTO notification_attempts
      (queue_id, attempt_number, channel, status, actor_id)
    VALUES
      (p_queue_id, v_attempt_num, 'email', 'sent', auth.uid());

  ELSE
    RAISE EXCEPTION
      'wf_retry_notification: nothing to retry (inapp_status=%, email_status=%)',
      v_queue.status, COALESCE(v_email_status, 'n/a');
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_retry_notification(uuid, boolean) IS
  'Admin retry for a single workflow_notification_queue row. '
  'Handles in-app re-delivery (Case 1) and email re-fire (Case 2) automatically. '
  'Pass p_force := true to bypass max_retries ceiling. '
  'Logs every attempt to notification_attempts.';


-- ════════════════════════════════════════════════════════════════════════════
-- 9. vw_notification_monitor
--
-- Joins workflow_notification_queue (primary) with notifications (email
-- status), templates, instances, and employee info.
-- overall_status and can_retry are computed columns the UI queries directly.
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_notification_monitor;

CREATE VIEW vw_notification_monitor AS
SELECT
  -- Queue identity
  q.id                                                              AS queue_id,
  q.notification_id,
  q.instance_id,
  q.template_code,

  -- Human-readable display ID (same pattern as vw_wf_operations)
  CASE
    WHEN wi.id IS NOT NULL THEN
      upper(
        CASE wi.module_code
          WHEN 'expense_reports'  THEN 'EXP'
          WHEN 'leave_requests'   THEN 'LVE'
          WHEN 'travel_requests'  THEN 'TRV'
          WHEN 'purchase_orders'  THEN 'PO'
          ELSE                         'WF'
        END
        || '-' || to_char(wi.created_at, 'YYYYMMDD')
        || '-' || upper(left(wi.id::text, 6))
      )
    ELSE 'N/A'
  END                                                               AS display_id,

  -- Template
  COALESCE(tpl.code, q.template_code)                               AS template_name,

  -- Recipient
  q.target_profile                                                  AS recipient_id,
  COALESCE(emp.name, 'Unknown')                                     AS recipient_name,
  emp.business_email                                                AS recipient_email,
  dept.name                                                         AS recipient_dept,

  -- Module / record
  wi.module_code,
  wi.record_id,

  -- In-app delivery
  q.status                                                          AS inapp_status,
  q.error_message                                                   AS inapp_error,
  q.retry_count,
  q.max_retries,

  -- Email delivery
  n.email_status,
  n.email_sent_at,
  n.email_error,

  -- Full payload for diagnostics
  q.payload,

  -- Timestamps
  q.created_at,
  q.processed_at,

  -- Computed: unified overall status for the monitor table
  CASE
    WHEN q.status = 'pending'                               THEN 'pending'
    WHEN q.status = 'failed'                                THEN 'failed'
    WHEN q.status = 'sent' AND n.email_status = 'failed'    THEN 'partial'
    WHEN q.status = 'sent' AND n.email_status = 'pending'   THEN 'partial'
    WHEN q.status = 'sent' AND n.email_status = 'skipped'   THEN 'inapp_only'
    WHEN q.status = 'sent' AND n.email_status = 'sent'      THEN 'delivered'
    ELSE 'inapp_only'   -- sent with no email record
  END                                                               AS overall_status,

  -- Computed: whether the retry button should be enabled
  CASE
    WHEN q.status = 'failed'
         AND q.retry_count < q.max_retries                  THEN true
    WHEN q.status = 'sent'
         AND n.email_status = 'failed'                      THEN true
    ELSE false
  END                                                               AS can_retry

FROM       workflow_notification_queue    q
LEFT JOIN  notifications                  n    ON n.id    = q.notification_id
LEFT JOIN  workflow_notification_templates tpl  ON tpl.code = q.template_code
LEFT JOIN  workflow_instances             wi   ON wi.id   = q.instance_id
LEFT JOIN  profiles                       p    ON p.id    = q.target_profile
LEFT JOIN  employees                      emp  ON emp.id  = p.employee_id
LEFT JOIN  departments                    dept ON dept.id = emp.dept_id;

COMMENT ON VIEW vw_notification_monitor IS
  'System-wide notification delivery view joining queue, in-app, and email channels. '
  'overall_status: delivered | inapp_only | partial | failed | pending. '
  'Readable by admin / workflow.admin only (enforced via table RLS).';


-- Indexes supporting common monitor queries
CREATE INDEX IF NOT EXISTS wf_notif_queue_status_created_idx
  ON workflow_notification_queue (status, created_at DESC);

CREATE INDEX IF NOT EXISTS wf_notif_queue_template_idx
  ON workflow_notification_queue (template_code, created_at DESC);

CREATE INDEX IF NOT EXISTS wf_notif_queue_target_profile_idx
  ON workflow_notification_queue (target_profile, created_at DESC);


-- ════════════════════════════════════════════════════════════════════════════
-- 10. pg_cron — auto-retry failed emails every 15 minutes
-- ════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Remove any previous schedule for this job name (safe to run repeatedly)
    BEGIN
      PERFORM cron.unschedule('retry-failed-notification-emails');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    PERFORM cron.schedule(
      'retry-failed-notification-emails',
      '*/15 * * * *',
      $cron$ SELECT wf_retry_failed_emails(24); $cron$
    );

    RAISE NOTICE 'pg_cron job ''retry-failed-notification-emails'' scheduled (*/15 * * * *)';
  ELSE
    RAISE NOTICE 'pg_cron not available — auto-retry job not scheduled';
  END IF;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- Verification
-- ════════════════════════════════════════════════════════════════════════════

-- app_config seeded
SELECT key, CASE WHEN value = '' THEN '(needs to be set)' ELSE '(set)' END AS status
FROM   app_config
WHERE  key IN ('supabase_functions_url', 'webhook_secret');

-- New columns on workflow_notification_queue
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'workflow_notification_queue'
  AND  column_name IN ('notification_id', 'retry_count', 'max_retries')
ORDER  BY column_name;

-- notification_attempts table
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'notification_attempts'
ORDER  BY ordinal_position;

-- View columns
SELECT column_name FROM information_schema.columns
WHERE  table_name = 'vw_notification_monitor'
ORDER  BY ordinal_position;

-- RPCs
SELECT proname FROM pg_proc
WHERE  proname IN (
  'wf_retry_notification',
  'wf_retry_failed_emails',
  'trg_wf_deliver_notification',
  'wf_deliver_pending_notifications'
)
ORDER  BY proname;
