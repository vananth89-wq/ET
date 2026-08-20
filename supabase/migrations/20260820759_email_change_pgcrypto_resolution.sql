-- Migration : 20260820759_email_change_pgcrypto_resolution.sql
-- Purpose   : Stop schema-qualifying pgcrypto in the email-change functions, and
--             prove at DEPLOY time that it resolves at all.
--
-- The bug being pre-empted :
--   758 calls extensions.gen_random_bytes() and extensions.digest(). That is
--   where Supabase installs pgcrypto, so it is right on every environment we
--   have. But 419001 creates the extension with a bare
--   `CREATE EXTENSION IF NOT EXISTS "pgcrypto"` and no SCHEMA clause, so on a
--   database where pgcrypto is NOT already present in extensions -- a local
--   stack, a self-hosted instance, a restored dump -- it lands in whatever the
--   creating role's search_path put first, and the qualified calls resolve to
--   nothing.
--
--   The reason this is worth its own migration rather than a shrug: a plpgsql
--   body is not resolved until it RUNS. 758 deploys green either way. The first
--   sign of trouble would be an HR administrator saving an email address and
--   getting `schema "extensions" does not exist` thrown into their face from a
--   trigger -- with the UPDATE rolled back, so the edit they just made silently
--   did not happen either.
--
--   Unqualified calls plus a search_path of `public, extensions` resolve
--   wherever pgcrypto actually is, and the assertion below turns a runtime
--   surprise into a failed deploy.
--
-- Depends on : 758

CREATE OR REPLACE FUNCTION public.trg_employee_email_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth
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

  -- MIG 759: unqualified, resolved through search_path.
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

  PERFORM extensions.http_post(
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
               )::text,
    timeout_milliseconds := 5000
  );

  RETURN NEW;
END
$fn$;


CREATE OR REPLACE FUNCTION public.claim_email_change_token(p_token text)
RETURNS TABLE (change_id uuid, profile_id uuid, new_email text, employee_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $fn$
DECLARE
  -- MIG 759: unqualified. Must hash identically to the trigger above, or every
  -- link ever issued stops matching — silently, since a non-match is
  -- indistinguishable from an expired token by design.
  v_hash text := encode(digest(p_token, 'sha256'), 'hex');
BEGIN
  RETURN QUERY
  SELECT c.id, c.profile_id, c.new_email, e.name
  FROM   employee_email_changes c
  JOIN   employees e ON e.id = c.employee_id
  WHERE  c.token_hash = v_hash
    AND  c.status     = 'pending'
    AND  c.expires_at > now();
END
$fn$;

REVOKE ALL ON FUNCTION public.claim_email_change_token(text) FROM PUBLIC, anon, authenticated;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- Run the primitives for real, in this session's search_path, so a database
-- where pgcrypto is missing or unreachable fails HERE rather than under an
-- administrator saving a form.
DO $chk$
DECLARE
  v_tok  text;
  v_hash text;
BEGIN
  BEGIN
    EXECUTE 'SET LOCAL search_path = public, extensions';
    SELECT encode(gen_random_bytes(32), 'hex')     INTO v_tok;
    SELECT encode(digest(v_tok, 'sha256'), 'hex')  INTO v_hash;
  EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
    RAISE EXCEPTION
      'mig 759 assert: pgcrypto is not reachable from search_path (public, extensions) — '
      'gen_random_bytes/digest do not resolve, so no email change could ever be issued '
      'or confirmed on this database';
  END;

  IF v_hash IS NULL OR length(v_hash) <> 64 THEN
    RAISE EXCEPTION 'mig 759 assert: sha256 did not produce a 64-character hex digest';
  END IF;

  -- Pending links were hashed by 758's qualified call. Same algorithm, same
  -- input, same digest — so this change cannot invalidate a link already in
  -- somebody's inbox. Stated because it is the obvious worry and the answer is
  -- not obvious from the diff.
  RAISE NOTICE 'mig 759: pgcrypto resolves unqualified; existing tokens unaffected';
END
$chk$;
