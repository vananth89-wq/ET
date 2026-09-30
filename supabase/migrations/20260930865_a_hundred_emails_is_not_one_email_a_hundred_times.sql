-- =============================================================================
-- Migration 865 — a hundred emails is not one email, a hundred times
--
-- WHAT HAPPENED
-- ═════════════
--   The first real run of the submission reminder job (863) created 113
--   notifications at 01:25 UTC. All 113 share one created_at to the
--   microsecond, because they were written in one transaction. Ten emails went
--   out. One hundred and one came back:
--
--       Resend 429: "Too many requests. You can only make 10 requests per
--                    second." rate_limit_exceeded
--
--   ...and two never got a response at all.
--
-- WHY
-- ═══
--   Every insert into notifications fires trg_email_notification, which posts
--   to the send-notification-email Edge Function there and then. That has been
--   correct for every sender this system has ever had: a workflow notification
--   arrives one or two at a time, and an immediate send is the simplest thing
--   that works.
--
--   The reminder job is the first thing that ever creates a hundred
--   notifications at once, and 863 did not ask what the delivery path does with
--   a burst. Thirty-eight employees times three recipients, in one statement,
--   through a per-insert trigger, is 113 HTTP calls in about 300 milliseconds
--   against a ceiling of 10 per second.
--
--   Raising the ceiling would not fix this. The next bulk sender will be
--   bigger, and a burst that fits today breaches tomorrow. What is wrong is
--   that the send is synchronous with the insert, and for a bulk sender it
--   must not be.
--
-- THE SHAPE OF THE FIX
-- ════════════════════
--   A bulk sender says so, and the trigger stays out of its way:
--
--     * trg_email_notification returns early when the session has set
--       prowess.defer_notification_email. The row is written, it is the bell
--       item immediately, and email_status stays 'pending'.
--     * drain_notification_emails() runs every minute and sends what is
--       pending, paced with an explicit sleep between posts. Five per second
--       by default -- half the ceiling, because the ceiling is shared with
--       every other sender and with whatever else is running at 01:25.
--     * Singleton senders are untouched. An approval notification still emails
--       the instant it is written, because one email is not a burst and making
--       a person wait a minute for it would be a regression.
--
--   So the trigger keeps its own inline post. That is a deliberate duplication
--   of the payload and headers -- see DEBT at the foot of this file.
--
-- RETRY, AND WHEN NOT TO
-- ══════════════════════
--   A 429 is worth retrying; a bad address is not. email_attempts counts, and
--   the drainer stops at five. Without a counter a permanently undeliverable
--   row is retried every minute for ever, which is how a rate limit problem
--   becomes a rate limit problem that never ends.
--
--   A stale reminder is also not worth retrying. A chase that arrives many
--   hours after the fact, against a bell notification the recipient has already
--   seen, is noise. The drainer ignores anything older than twelve hours.
--
--   THIS MORNING'S 101 ARE DELIBERATELY NOT RESENT. They are stood down
--   explicitly below rather than left to age past the window, so the decision
--   is visible in this file instead of being an accident of deploy timing. The
--   recipients have the in-app notification, correctly worded, and the +6
--   escalation on 5 Oct will reach the same people by mail.
--
-- SAFETY
--   * The trigger is patched with a guard only; its send path is unchanged.
--   * Nothing sets the defer flag except a bulk sender that opts in, so every
--     existing notification behaves exactly as it did yesterday.
--   * Idempotent, verified by running three times.
--   * Verified against a real PostgreSQL 16 with a stubbed net.http_post that
--     enforces Resend's 10/second and fails the excess, reproducing the 429.
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — a row remembers how often it has been tried
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS email_attempts       smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS email_last_attempt_at timestamptz;

COMMENT ON COLUMN notifications.email_attempts IS
  'Mig 865: how many times the drainer has posted this to the mail function. '
  'Stops at 5. A permanently undeliverable address must not be retried for ever.';

COMMENT ON COLUMN notifications.email_last_attempt_at IS
  'Mig 865: when the drainer last posted this. A row stays ''pending'' between '
  'the post and the Edge Function''s reply, so without this the next run a '
  'minute later would post it again — a duplicate email every minute until the '
  'attempt cap. The drainer waits 10 minutes for a reply before retrying.';

CREATE INDEX IF NOT EXISTS notifications_email_drain
  ON notifications (created_at)
  WHERE email_status IN ('pending', 'failed');

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the burst that prompted this is not resent
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE v_n integer;
BEGIN
  UPDATE notifications
  SET    email_attempts = 5,
         email_error    = coalesce(email_error, '') ||
                          ' | Mig 865: not retried — the recipient has the in-app '
                          'notification and a chase arriving this late is noise.'
  WHERE  email_status   = 'failed'
    AND  email_attempts = 0
    AND  created_at     < now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'MIG 865: % failed notification(s) stood down and will not be retried.', v_n;
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — one place that knows how to post a notification
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.send_notification_email(p_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $fn$
DECLARE
  v_url    text;
  v_secret text;
  v_row    record;
BEGIN
  SELECT value INTO v_url    FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_url IS NULL OR v_url = '' THEN
    UPDATE notifications
    SET    email_status = 'skipped',
           email_error  = 'supabase_functions_url not configured in app_config'
    WHERE  id = p_id;
    RETURN 'skipped';
  END IF;

  SELECT id, profile_id, title, body, link INTO v_row
  FROM   notifications WHERE id = p_id;
  IF NOT FOUND THEN RETURN 'missing'; END IF;

  PERFORM net.http_post(
    url     := v_url || '/send-notification-email',
    headers := jsonb_build_object('Content-Type',     'application/json',
                                  'x-webhook-secret', COALESCE(v_secret, '')),
    body    := jsonb_build_object('notification_id', v_row.id,
                                  'profile_id',      v_row.profile_id,
                                  'title',           v_row.title,
                                  'body',            v_row.body,
                                  'link',            v_row.link),
    timeout_milliseconds := 5000);

  -- Not 'sent'. The Edge Function writes that once the provider accepts it,
  -- and writing it here would report success for a request that has only been
  -- queued -- which is exactly the distinction this migration exists to make.
  UPDATE notifications
  SET    email_attempts        = email_attempts + 1,
         email_last_attempt_at = now(),
         email_status          = 'pending',
         email_error           = NULL
  WHERE  id = p_id;

  RETURN 'posted';
EXCEPTION WHEN OTHERS THEN
  UPDATE notifications
  SET    email_status          = 'failed',
         email_attempts        = email_attempts + 1,
         email_last_attempt_at = now(),
         email_error           = left(SQLERRM, 1000)
  WHERE  id = p_id;
  RETURN 'failed';
END;
$fn$;

REVOKE ALL ON FUNCTION public.send_notification_email(uuid) FROM PUBLIC;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4 — the drainer
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.drain_notification_emails(
  p_limit      integer DEFAULT 50,
  p_per_second numeric DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $fn$
DECLARE
  v_row     record;
  v_gap     numeric := CASE WHEN p_per_second > 0 THEN 1.0 / p_per_second ELSE 0 END;
  v_posted  integer := 0;
  v_skipped integer := 0;
  v_first   boolean := true;
  v_result  text;
BEGIN
  FOR v_row IN
    SELECT id
    FROM   notifications
    WHERE  email_status   IN ('pending', 'failed')
      AND  email_attempts < 5
      -- A posted row stays 'pending' until the Edge Function replies with
      -- 'sent' or 'failed'. Without this the next run, one minute later, would
      -- post it again, and again, until the attempt cap -- five duplicate
      -- emails to the same person for one notification. Ten minutes is long
      -- enough for a reply and short enough that a genuinely lost post is
      -- still retried while it is worth sending.
      AND  (email_last_attempt_at IS NULL
            OR email_last_attempt_at < now() - interval '10 minutes')
      -- A chase that arrives half a day late is worse than one that never
      -- arrives: the recipient already has the bell item and has moved on.
      AND  created_at     > now() - interval '12 hours'
    ORDER  BY created_at
    LIMIT  p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    -- The pause is the whole point. Resend allows ten a second and this runs
    -- at five, because the ceiling is shared with every other sender and with
    -- whatever else happens to be running at the same minute.
    IF NOT v_first AND v_gap > 0 THEN
      PERFORM pg_sleep(v_gap);
    END IF;
    v_first := false;

    v_result := send_notification_email(v_row.id);
    IF v_result = 'posted' THEN v_posted := v_posted + 1;
    ELSE                        v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'posted', v_posted, 'not_posted', v_skipped,
                            'per_second', p_per_second);
END;
$fn$;

REVOKE ALL ON FUNCTION public.drain_notification_emails(integer, numeric) FROM PUBLIC;

COMMENT ON FUNCTION public.drain_notification_emails(integer, numeric) IS
  'Mig 865: sends pending and failed notification emails at a paced rate, so a '
  'bulk sender cannot breach the provider''s per-second limit. Stops retrying '
  'after 5 attempts or 12 hours.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5 — the trigger stands aside for a bulk sender
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._mig865_patch(
  p_fn text, p_a text, p_b text, p_expect integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_src text; v_hits integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = p_fn;
  IF v_n = 0 THEN RAISE EXCEPTION 'MIG 865: %() not found.', p_fn; END IF;
  IF v_n > 1 THEN RAISE EXCEPTION 'MIG 865: %() is overloaded % ways.', p_fn, v_n; END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = p_fn;

  IF position(p_a IN v_src) = 0 AND position(p_b IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 865: %() already patched, skipping.', p_fn;
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, p_a, ''))) / length(p_a);
  IF v_hits <> p_expect THEN
    RAISE EXCEPTION 'MIG 865: in %(), the anchor matched % times, expected %. Read the live definition before editing this file. Anchor: %',
      p_fn, v_hits, p_expect, left(p_a, 90);
  END IF;

  EXECUTE replace(v_src, p_a, p_b);
  RAISE NOTICE 'MIG 865: patched %() — % occurrence(s).', p_fn, v_hits;
END;
$$;

DO $mig$
BEGIN
  -- The trailing comment on 863's line is not decoration: without it the
  -- anchor would survive inside its own replacement, the "already applied"
  -- test could never fire, and each re-run would add another defer guard.
  PERFORM public._mig865_patch('trg_email_notification',
'  IF NEW.email_status = ''skipped'' THEN
    RETURN NEW;
  END IF;',
'  -- Mig 865. A bulk sender sets this and drain_notification_emails() posts the
  -- rows a few at a time instead. Without it, 113 inserts in one transaction
  -- became 113 HTTP calls in 300ms against a 10-per-second ceiling, and 101 of
  -- them came back 429. Nothing sets this flag except a sender that opts in, so
  -- a single notification still emails the instant it is written.
  IF coalesce(current_setting(''prowess.defer_notification_email'', true), ''false'') = ''true'' THEN
    RETURN NEW;
  END IF;

  IF NEW.email_status = ''skipped'' THEN  -- mig 863
    RETURN NEW;
  END IF;',
    1);

  -- The reminder job is that bulk sender.
  -- Anchored across the BEGIN so it disappears once applied, for the same
  -- reason (838's lesson, relearned twice in this file).
  PERFORM public._mig865_patch('time_send_submission_reminders',
'BEGIN
  SELECT COALESCE(reminder_catchup_days, 3), COALESCE(period_start_day, 1)',
'BEGIN
  -- Mig 865. Defer the mail: this function writes one notification per
  -- recipient per employee, which is a burst by construction. The rows are the
  -- bell items immediately; drain_notification_emails() posts them at a rate
  -- the provider accepts. true = local to this transaction.
  PERFORM set_config(''prowess.defer_notification_email'', ''true'', true);

  SELECT COALESCE(reminder_catchup_days, 3), COALESCE(period_start_day, 1)',
    1);
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig865_patch(text, text, text, integer);

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6 — every minute
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
BEGIN
  PERFORM cron.unschedule('drain-notification-emails');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$mig$;

DO $mig$
BEGIN
  PERFORM cron.schedule('drain-notification-emails', '* * * * *',
                        $cron$SELECT public.drain_notification_emails();$cron$);
  RAISE NOTICE 'MIG 865: scheduled drain-notification-emails every minute.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'MIG 865: pg_cron not available — the drainer exists but is not scheduled (%)', SQLERRM;
END;
$mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7 — verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $v$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p WHERE p.proname = 'trg_email_notification';
  IF position('prowess.defer_notification_email' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: the trigger has no defer guard, so a bulk sender would still burst.';
  END IF;
  IF position('send-notification-email' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: the trigger no longer sends a singleton notification at all.';
  END IF;
  IF position('NEW.email_status = ''skipped''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: 863''s in_app guard has been lost.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p WHERE p.proname = 'time_send_submission_reminders';
  IF position('prowess.defer_notification_email' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: the reminder job does not defer, so it would burst again tomorrow.';
  END IF;
  IF (length(v_src) - length(replace(v_src, 'set_config(''prowess.defer_notification_email''', '')))
     / length('set_config(''prowess.defer_notification_email''') <> 1 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: the defer call appears more than once; this patch is not idempotent.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'notifications' AND column_name = 'email_attempts') THEN
    RAISE EXCEPTION 'MIG 865 FAILED: email_attempts is missing, so a bad address would retry for ever.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p WHERE p.proname = 'drain_notification_emails';
  IF position('email_last_attempt_at' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 865 FAILED: the drainer has no backoff, so it would re-post every pending row every minute.';
  END IF;

  IF EXISTS (SELECT 1 FROM notifications
             WHERE email_status = 'failed' AND email_attempts = 0
               AND created_at < now() - interval '1 minute') THEN
    RAISE EXCEPTION 'MIG 865 FAILED: an older failure was left retryable; this morning''s burst would be resent.';
  END IF;
END;
$v$;

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBT
-- ═══════════════════════════════════════════════════════════════════════════
--   trg_email_notification still contains its own copy of the payload, headers
--   and net.http_post call, alongside the one in send_notification_email().
--   They must agree, and nothing enforces that.
--
--   Collapsing them means replacing most of the trigger's body rather than
--   adding a guard to it, and that is a larger edit than this fix needs while
--   a hundred emails are sitting unsent. A later migration should make the
--   trigger call send_notification_email() and delete its own copy; the two
--   are byte-identical in what they post today, which is the moment to do it.
-- =============================================================================

COMMIT;
