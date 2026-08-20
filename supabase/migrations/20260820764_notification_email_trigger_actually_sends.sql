-- Migration : 20260820764_notification_email_trigger_actually_sends.sql
-- Purpose   : Make the notification email trigger work, and make its failures
--             visible. It has been throwing on every single notification and
--             saying nothing.
--
-- WHAT WAS WRONG
--   trg_email_notification (mig 427035) calls
--       net.http_post(... body := v_payload::text ...)
--   net.http_post takes body as JSONB. pg_net 0.20.3 has no text-body overload,
--   so the named-argument call resolves to nothing and raises
--       function net.http_post(url => text, headers => jsonb, body => text,
--                              timeout_milliseconds => integer) does not exist
--   Verified against the LIVE definition via pg_get_functiondef, not the file --
--   the two matched, so nothing had patched it since April.
--
-- WHY NOBODY NOTICED, WHICH IS THE REAL DEFECT
--   The handler is:
--       EXCEPTION WHEN OTHERS THEN
--         RAISE NOTICE '...'; RETURN NEW;
--   A NOTICE goes to the Postgres log and nowhere a human looks. The INSERT
--   succeeds, notifications.email_status stays NULL, and
--   vw_notification_monitor's CASE falls to its ELSE and labels the row
--   "In-App Only" -- the same badge a deliberately in-app-only notification
--   gets. **A total failure of the email leg was rendered as a design choice.**
--   112 rows on Dev sit in that state.
--
--   Worse, wf_retry_failed_emails only picks up email_status = 'failed'. A row
--   the trigger never marked is never retried, so the failure was not only
--   invisible but permanent.
--
--   Swallowing the exception is still right -- an email must never block the
--   notification INSERT, and 427035's comment says so. What was wrong was
--   swallowing it WITHOUT A TRACE. This migration keeps the catch and records
--   the reason on the row, which both surfaces it in the monitor and makes it
--   eligible for the existing retry job.
--
-- NOT DOING: back-filling the 112 historical NULLs to 'failed'. That would make
--   them retry-eligible and fire months of stale approval emails at people. They
--   stay as they are; the monitor's In-App Only badge is accurate enough for
--   history, and this migration only changes what happens from now on.
--
-- Built as a full CREATE OR REPLACE from the LIVE body (captured 2026-08-20 via
--   pg_get_functiondef and confirmed identical to 427035), NOT from the file --
--   see the 734/736/737 lesson. The only changes are the cast, the search_path,
--   and the handler.
--
-- Depends on : 427035 (the trigger), 430074 (the correct call shape),
--              762 (same class of bug in two other functions)

CREATE OR REPLACE FUNCTION public.trg_email_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
-- MIG 764: `net` added. The call is schema-qualified regardless, but the path
-- makes the dependency legible.
SET search_path = public, net, extensions
AS $function$
DECLARE
  v_functions_url  text;
  v_webhook_secret text;
  v_payload        jsonb;
BEGIN
  SELECT value INTO v_functions_url  FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_webhook_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_functions_url IS NULL OR v_functions_url = '' THEN
    -- Recorded on the row, not just raised. 'skipped' is the honest word: it was
    -- never attempted, and it is not the Edge Function's fault.
    UPDATE notifications
    SET    email_status = 'skipped',
           email_error  = 'supabase_functions_url not configured in app_config'
    WHERE  id = NEW.id;
    RETURN NEW;
  END IF;

  v_payload := jsonb_build_object(
    'notification_id', NEW.id,
    'profile_id',      NEW.profile_id,
    'title',           NEW.title,
    'body',            NEW.body,
    'link',            NEW.link
  );

  -- MIG 764: body is jsonb. The ::text cast here is what broke every email.
  PERFORM net.http_post(
    url     := v_functions_url || '/send-notification-email',
    headers := jsonb_build_object(
                 'Content-Type',      'application/json',
                 'x-webhook-secret',  COALESCE(v_webhook_secret, '')
               ),
    body    := v_payload,
    timeout_milliseconds := 5000
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- Still never block the INSERT -- a person's approval must not fail because
  -- an email could not be queued. But leave evidence: 'failed' is what
  -- wf_retry_failed_emails looks for, and what the monitor renders in amber.
  --
  -- This UPDATE cannot recurse: the trigger is AFTER INSERT only.
  BEGIN
    UPDATE notifications
    SET    email_status = 'failed',
           email_error  = left(SQLERRM, 1000)
    WHERE  id = NEW.id;
  EXCEPTION WHEN OTHERS THEN
    NULL;   -- if even that fails, the NOTICE below is all we have
  END;

  RAISE NOTICE 'trg_email_notification: error queuing email for notification % — %',
               NEW.id, SQLERRM;
  RETURN NEW;
END;
$function$;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- This migration exists because a broken call looked fine in the source and
-- failed only at run time, into a handler nobody read. So prove the call
-- resolves and prove the cast is gone.
DO $chk$
DECLARE
  v_src  text;
  v_n    int;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'net' AND p.proname = 'http_post'
    AND  pg_get_function_arguments(p.oid) LIKE '%body jsonb%';

  IF v_n = 0 THEN
    RAISE EXCEPTION
      'mig 764 assert: no net.http_post overload takes a jsonb body — check the '
      'installed pg_net version before changing this call again';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'trg_email_notification';

  IF position('v_payload::text' IN v_src) > 0 THEN
    RAISE EXCEPTION 'mig 764 assert: the ::text cast survived';
  END IF;

  IF position('email_status = ''failed''' IN v_src) = 0 THEN
    RAISE EXCEPTION
      'mig 764 assert: the exception handler does not record the failure — a '
      'silent swallow is the defect this migration exists to remove';
  END IF;

  -- The trigger must still be AFTER INSERT only, or the UPDATE above recurses.
  SELECT count(*) INTO v_n
  FROM   pg_trigger t
  WHERE  t.tgname = 'after_notification_insert_send_email'
    AND  NOT t.tgisinternal
    AND  (t.tgtype & 4) <> 0      -- INSERT
    AND  (t.tgtype & 16) = 0;     -- not UPDATE

  IF v_n <> 1 THEN
    RAISE EXCEPTION
      'mig 764 assert: after_notification_insert_send_email is not INSERT-only — '
      'the failure UPDATE would recurse';
  END IF;

  RAISE NOTICE 'mig 764: notification emails now dispatch, and failures are recorded';
END
$chk$;
