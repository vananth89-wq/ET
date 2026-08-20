-- Migration : 20260820762_http_post_is_in_net_and_takes_jsonb.sql
-- Purpose   : Fix the pg_net call in trg_employee_email_change, and the same
--             error in wf_retry_notification, which has been live and broken
--             since April.
--
-- The error, as an administrator saw it :
--   Saving an employee's Business Email threw
--     function extensions.http_post(url => text, headers => jsonb,
--                                   body => text, timeout_milliseconds => integer)
--     does not exist
--   and the UPDATE rolled back with it -- so the edit did not happen either.
--   Exactly the failure 759 was written to pre-empt for pgcrypto, in the
--   function immediately below it, missed because I checked one dependency and
--   not its neighbour.
--
-- Two things are wrong with that call, and both were copied :
--   1. SCHEMA. pg_net installs into `net`, not `extensions`.
--   2. TYPE.   http_post takes body as JSONB. The call casts it ::text.
--
--   I took both from 20260428052_notification_monitor.sql -- which is the
--   SUPERSEDED version. 20260430074 had already rewritten
--   wf_retry_failed_emails to `net.http_post(... body := jsonb_build_object(...))`
--   with no cast, and 20260727691 -- the most recent caller in the repo -- does
--   the same. I copied the oldest of three call sites without checking whether a
--   later one disagreed. The lesson is the one this repo keeps relearning: when
--   several migrations touch the same call, the newest is the specification.
--
-- The second fix, which is not mine :
--   wf_retry_notification (mig 428052, the per-row Retry button in the
--   Notification Monitor) still carries the same broken call. 430074 fixed its
--   sibling wf_retry_failed_emails and left this one. It has therefore thrown
--   this error every time anyone has clicked Retry on a single failed
--   notification since April -- silently, because the button reports a generic
--   failure and the retry it was meant to perform looks like just another
--   failure.
--
--   Patched IN PLACE rather than rewritten. pg_get_functiondef is the only
--   honest source for a function that may have been patched since its file was
--   written, and a CREATE OR REPLACE built from 428052 would revert anything
--   applied after it -- the defect behind 734, 736 and 737. Hit counts are
--   asserted, so a silent no-op fails the deploy.
--
-- Depends on : 761 (the trigger being fixed), 428052 (wf_retry_notification),
--              430074 (the correct call, already in production)

-- ── 1. The trigger ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_employee_email_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
-- MIG 762: `net` added. The call below is schema-qualified anyway, as 691 does,
-- but the path makes the dependency legible to whoever reads this next.
SET search_path = public, net, extensions, auth
AS $fn$
DECLARE
  v_profile_id  uuid;
  v_auth_email  text;
  v_token       text;
  v_change_id   uuid;
  v_expires     timestamptz := now() + interval '7 days';
  v_url         text;
  v_secret      text;
BEGIN
  IF NEW.business_email IS NULL
     OR NEW.business_email IS NOT DISTINCT FROM OLD.business_email THEN
    RETURN NEW;
  END IF;

  SELECT p.id, u.email
  INTO   v_profile_id, v_auth_email
  FROM   profiles p
  JOIN   auth.users u ON u.id = p.id
  WHERE  p.employee_id = NEW.id
  LIMIT  1;

  IF v_profile_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(v_auth_email, '')) = lower(NEW.business_email) THEN
    UPDATE employee_email_changes
    SET    status = 'superseded', resolved_at = now()
    WHERE  employee_id = NEW.id AND status = 'pending';
    RETURN NEW;
  END IF;

  UPDATE employee_email_changes
  SET    status = 'superseded', resolved_at = now()
  WHERE  employee_id = NEW.id AND status = 'pending';

  v_token := encode(gen_random_bytes(32), 'hex');

  INSERT INTO employee_email_changes
    (employee_id, profile_id, old_email, new_email, token_hash,
     requested_by, expires_at)
  VALUES
    (NEW.id, v_profile_id, v_auth_email, NEW.business_email,
     encode(digest(v_token, 'sha256'), 'hex'),
     auth.uid(), v_expires)
  RETURNING id INTO v_change_id;

  SELECT value INTO v_url    FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_url IS NULL OR v_url = '' THEN
    UPDATE employee_email_changes
    SET    email_status = 'skipped',
           error_message = 'supabase_functions_url not configured in app_config'
    WHERE  id = v_change_id;
    RAISE WARNING
      'employee email change raised for % but no functions URL is configured — '
      'the verification email was not sent', NEW.business_email;
    RETURN NEW;
  END IF;

  -- MIG 762: net.http_post, and body as jsonb with no ::text cast.
  PERFORM net.http_post(
    url     := v_url || '/send-email-change-verification',
    headers := jsonb_build_object(
                 'Content-Type',     'application/json',
                 'x-webhook-secret', COALESCE(v_secret, '')
               ),
    body    := jsonb_build_object(
                 'change_id',     v_change_id,
                 'token',         v_token,
                 'employee_name', NEW.name,
                 'old_email',     v_auth_email,
                 'new_email',     NEW.business_email,
                 'expires_at',    v_expires
               ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;
END
$fn$;


-- ── 2. wf_retry_notification, patched in place ───────────────────────────────
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'wf_retry_notification';

  IF v_src IS NULL THEN
    RAISE NOTICE 'mig 762: wf_retry_notification not present — nothing to patch';
    RETURN;
  END IF;

  IF position('extensions.http_post' IN v_src) = 0 THEN
    RAISE NOTICE 'mig 762: wf_retry_notification already calls net.http_post';
    RETURN;
  END IF;

  v_new := v_src;

  v_hits := (length(v_new) - length(replace(v_new, 'extensions.http_post', ''))) / length('extensions.http_post');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 762: expected 1 extensions.http_post in wf_retry_notification, found %', v_hits;
  END IF;
  v_new := replace(v_new, 'extensions.http_post', 'net.http_post');

  -- The cast sits on the closing paren of the body's jsonb_build_object. It is
  -- the only ")::text," in this function; asserted rather than assumed, because
  -- a miss here leaves the schema right and the type still wrong.
  v_hits := (length(v_new) - length(replace(v_new, ')::text,', ''))) / length(')::text,');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 762: expected 1 body ::text cast in wf_retry_notification, found %', v_hits;
  END IF;
  v_new := replace(v_new, ')::text,', '),');

  IF position('SET search_path' IN v_new) > 0 AND position(', net' IN v_new) = 0 THEN
    v_new := replace(v_new, 'SET search_path TO ', 'SET search_path TO net, ');
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'mig 762: wf_retry_notification now calls net.http_post with a jsonb body';
END
$mig$;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- The point of asserting rather than trusting: this whole migration exists
-- because a call that does not resolve looks perfectly fine in the source and
-- only fails when a human presses Save.
DO $chk$
DECLARE
  v_src   text;
  v_bad   int;
  v_proof int;
BEGIN
  -- pg_net must actually be reachable at the name we now use.
  SELECT count(*) INTO v_proof
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'net' AND p.proname = 'http_post';

  IF v_proof = 0 THEN
    RAISE EXCEPTION
      'mig 762 assert: net.http_post does not exist — pg_net is not installed in '
      'schema net on this database, so no outbound call in this codebase can work';
  END IF;

  -- And it must accept a jsonb body, which is the half of the bug that the
  -- schema fix alone would not have caught.
  SELECT count(*) INTO v_proof
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'net' AND p.proname = 'http_post'
    AND  pg_get_function_arguments(p.oid) LIKE '%body jsonb%';

  IF v_proof = 0 THEN
    RAISE EXCEPTION
      'mig 762 assert: no net.http_post overload takes a jsonb body — check the '
      'installed pg_net version before changing these call sites again';
  END IF;

  SELECT count(*) INTO v_bad
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname IN ('trg_employee_email_change', 'wf_retry_notification')
    AND  pg_get_functiondef(p.oid) LIKE '%extensions.http_post%';

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'mig 762 assert: % function(s) still call extensions.http_post', v_bad;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'trg_employee_email_change';

  IF position(')::text' IN v_src) > 0 THEN
    RAISE EXCEPTION 'mig 762 assert: trg_employee_email_change still casts its body to text';
  END IF;

  RAISE NOTICE 'mig 762: outbound calls fixed; net.http_post resolves and takes jsonb';
END
$chk$;
