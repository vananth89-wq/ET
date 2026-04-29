-- =============================================================================
-- pg_cron Schedules
--
-- Registers the background job schedules that were skipped during the original
-- jobs-framework migration (20260427033) if pg_cron was not yet enabled at
-- that time.
--
-- PRE-REQUISITE (one-time, via Supabase Dashboard):
--   Database → Extensions → search "pg_cron" → Enable
--
-- Jobs registered here:
--   1. wf-sla-monitor        — every 5 minutes
--      Calls wf_process_sla_events(NULL): scans pending workflow tasks,
--      sends reminder notifications when reminder_after_hours is crossed,
--      escalates to line manager when escalation_after_hours is crossed.
--
--   2. wf-notification-flush — every 1 minute
--      Calls wf_flush_notification_queue(): drains workflow_notification_queue
--      rows into the notifications table so the email trigger fires.
--
-- Both jobs are idempotent: unschedule-then-reschedule so re-running this
-- migration is always safe.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. wf_flush_notification_queue  (helper — drains the workflow queue)
-- ════════════════════════════════════════════════════════════════════════════
--
-- The workflow engine inserts rows into workflow_notification_queue rather than
-- directly into notifications so that a failed send never rolls back the
-- approval transaction.  This function moves queued rows into notifications
-- where the existing trigger picks them up and fires the email Edge Function.
--
-- Already called inline after approve/reject RPCs in Phase 1 migration,
-- but the cron schedule ensures any rows left behind (e.g. from escalations)
-- are also flushed.


CREATE OR REPLACE FUNCTION wf_flush_notification_queue(
  p_batch_size integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row   RECORD;
  v_title text;
  v_body  text;
  v_key   text;
  v_val   text;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT
      q.id,
      q.instance_id,
      q.target_profile,
      q.payload,
      t.title_tmpl,
      t.body_tmpl
    FROM   workflow_notification_queue  q
    JOIN   workflow_notification_templates t ON t.code = q.template_code
    WHERE  q.processed_at IS NULL
    ORDER  BY q.created_at
    LIMIT  p_batch_size
    FOR UPDATE OF q SKIP LOCKED
  LOOP
    -- Start with the raw templates
    v_title := v_row.title_tmpl;
    v_body  := v_row.body_tmpl;

    -- Replace each {{key}} token from the payload jsonb
    IF v_row.payload IS NOT NULL THEN
      FOR v_key, v_val IN
        SELECT key, value #>> '{}'
        FROM   jsonb_each(v_row.payload)
      LOOP
        v_title := replace(v_title, '{{' || v_key || '}}', COALESCE(v_val, ''));
        v_body  := replace(v_body,  '{{' || v_key || '}}', COALESCE(v_val, ''));
      END LOOP;
    END IF;

    -- Write to notifications (the existing INSERT trigger fires the email)
    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_row.target_profile,
      v_title,
      v_body,
      '/workflow/my-requests'
    );

    -- Mark queue row processed
    UPDATE workflow_notification_queue
    SET    processed_at = now()
    WHERE  id = v_row.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'wf_flush_notification_queue error: %', SQLERRM;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_flush_notification_queue(integer) IS
  'Drains workflow_notification_queue into notifications (max p_batch_size rows per call). '
  'Interpolates {{token}} placeholders from the payload jsonb into the template strings. '
  'Idempotent via processed_at column. Called by pg_cron every minute.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Register pg_cron schedules
-- ════════════════════════════════════════════════════════════════════════════
--
-- Wrapped in a DO block so that if pg_cron is still not enabled the migration
-- won't fail — it will just print a NOTICE.  Once you enable the extension in
-- the Supabase Dashboard (Database → Extensions → pg_cron), re-run this block
-- or re-run the migration to activate the schedules.

DO $$
BEGIN

  -- ── Job 1: SLA Monitor — every 5 minutes ─────────────────────────────────
  -- Unschedule first (safe if it doesn't exist — cron.unschedule is a no-op)
  BEGIN
    PERFORM cron.unschedule('wf-sla-monitor');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'wf-sla-monitor',
    '*/5 * * * *',                          -- every 5 minutes
    'SELECT wf_process_sla_events(NULL)'
  );
  RAISE NOTICE 'pg_cron: wf-sla-monitor scheduled (every 5 min)';

  -- ── Job 2: Notification Flush — every 1 minute ───────────────────────────
  BEGIN
    PERFORM cron.unschedule('wf-notification-flush');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'wf-notification-flush',
    '* * * * *',                            -- every 1 minute
    'SELECT wf_flush_notification_queue(100)'
  );
  RAISE NOTICE 'pg_cron: wf-notification-flush scheduled (every 1 min)';

  -- ── Job 3: Log Pruner — daily at 2 am ────────────────────────────────────
  BEGIN
    PERFORM cron.unschedule('job-log-prune');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'job-log-prune',
    '0 2 * * *',
    'DELETE FROM job_run_log WHERE created_at < now() - interval ''30 days'''
  );
  RAISE NOTICE 'pg_cron: job-log-prune scheduled (daily at 2am)';

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron extension not available — schedules skipped. '
               'Enable pg_cron in Dashboard → Database → Extensions, then re-run this migration. '
               'Error: %', SQLERRM;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Verify
-- ════════════════════════════════════════════════════════════════════════════

-- Show registered cron jobs (only works if pg_cron is enabled)
SELECT jobname, schedule, command, active
FROM   cron.job
WHERE  jobname IN ('wf-sla-monitor', 'wf-notification-flush')
ORDER  BY jobname;
