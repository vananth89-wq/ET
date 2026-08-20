-- Migration : 20260820761_business_email_is_the_login.sql
--
-- Renumbered : was 20260820758, which never reached any database. That version
--              had already been recorded by
--              20260820758_project_type_follows_the_house_rules.sql, so
--              `supabase db push` treated this file as applied and skipped it
--              WITHOUT SAYING SO. The run went red for an unrelated reason and
--              the skip was invisible underneath it. Confirmed after the fact
--              from supabase_migrations.schema_migrations, which named 758 as
--              project_type.
--
-- 759 IS FOLDED IN, deliberately. 759 replaced trg_employee_email_change and
--              claim_email_change_token with unqualified pgcrypto calls, and it
--              DID apply. Re-issuing this file with the original
--              `extensions.digest(...)` bodies would quietly revert it -- a
--              CREATE OR REPLACE built from an older file undoing a later patch,
--              which is the defect behind migrations 734, 736 and 737 and is
--              written up in the timesheet test plan. So the bodies below carry
--              759's unqualified calls, and the assertion at the foot proves
--              pgcrypto resolves before anything depends on it.
--
--              The result is order-independent: 759 then 761, or 761 alone on a
--              fresh database, both end with the same function bodies.
-- Purpose   : Make employees.business_email the system of record for a person's
--             login, with the new address verified before it takes effect.
--
-- The gap this closes :
--   activate-employee reads business_email and creates the auth user from it --
--   but ONLY if no auth user already matches, and only at activation. Nothing
--   anywhere updates an existing auth.users row: `updateUserById` appears once
--   in the whole codebase, in admin-password-reset, and never passes `email`.
--   So HR and the login are seeded together once and then diverge freely, in
--   silence, forever. Editing an employee's business_email today changes a field
--   nobody authenticates against, while every notification email continues to go
--   to the old address -- send-notification-email resolves the recipient through
--   auth.admin.getUserById, not through employees.
--
-- Shape of the fix :
--   1. An edit to business_email raises a PENDING change and mails a one-time
--      link to the NEW address.
--   2. Clicking it swaps auth.users.email. Until then the old address remains
--      the login, so a typo cannot lock anyone out of their own account.
--   3. Unclicked, it expires after 7 days and the person who made the edit is
--      told. Divergence is therefore always either brief or loud -- never both
--      permanent and invisible, which is the state we are in today.
--
-- Permission -- deliberately none of its own :
--   The trigger fires AFTER an UPDATE that RLS has already allowed. Writing
--   business_email on an Active employee needs employee_details.edit (policy
--   employees_update, mig 519261); on a Draft it needs hire_employee.edit; and
--   an employee editing their own record needs personal_info.edit. Re-checking
--   any of that here would be a second copy of the rule, free to drift from the
--   first. Whoever could change the field could already change it; this decides
--   what that change now MEANS.
--
--   The consequence worth stating plainly: employee_details.edit is now an
--   account-takeover primitive in one step rather than two. It always was --
--   an admin who can edit a record could already reset the password through
--   admin-password-reset -- but this makes it reachable by changing a text
--   field, so the audit row below is not decoration.
--
-- Self-service is included on purpose. MyProfile writes business_email too. The
--   trigger keys on the COLUMN, not on the caller, so an employee moving their
--   own address must still prove they hold the new mailbox. One code path, and
--   no way to put HR and the login out of step by using the other screen.
--
-- The token is never stored. Only sha256(token) is kept; the raw value exists in
--   the pg_net payload to our own Edge Function and in the recipient's inbox. A
--   leaked database backup therefore does not contain a usable link.
--
-- Depends on : 519261 (employees_update RLS), 428052 (app_config +
--              extensions.http_post pattern), 709688 (profiles <-> auth.users)

-- ── 1. The pending-change record ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.employee_email_changes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  profile_id    uuid NOT NULL REFERENCES public.profiles(id)  ON DELETE CASCADE,

  -- The auth login as it stood when the change was raised. NOT
  -- OLD.business_email: those two are already out of step on any record edited
  -- before this migration, and the honest "from" is what the person actually
  -- signs in with.
  old_email     text NOT NULL,
  new_email     text NOT NULL,

  token_hash    text NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','verified','cancelled','expired','superseded')),

  requested_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  resolved_at   timestamptz,

  email_status  text,
  error_message text
);

-- One live request per employee. A second edit supersedes the first rather than
-- leaving two valid links in two different inboxes.
CREATE UNIQUE INDEX IF NOT EXISTS employee_email_changes_one_pending
  ON public.employee_email_changes (employee_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS employee_email_changes_token
  ON public.employee_email_changes (token_hash)
  WHERE status = 'pending';

COMMENT ON TABLE public.employee_email_changes IS
  'Audit and pending-state for changes to a person''s login address. Raised by a '
  'trigger on employees.business_email, resolved by the confirm-email-change '
  'Edge Function. Immutable from the client: SELECT only, no INSERT/UPDATE/DELETE '
  'policies exist, so the row cannot be forged or back-dated from the browser.';

ALTER TABLE public.employee_email_changes ENABLE ROW LEVEL SECURITY;

-- Readable by anyone who can see the employee's details, so the pending badge
-- can render. No write policies at all -- every write is SECURITY DEFINER.
DROP POLICY IF EXISTS employee_email_changes_select ON public.employee_email_changes;
CREATE POLICY employee_email_changes_select ON public.employee_email_changes
  FOR SELECT USING (
    user_can('employee_details', 'view', employee_id)
    OR user_can('personal_info',  'view', employee_id)
  );


-- ── 2. Raise the change, and post the verification ───────────────────────────
-- Insert and delivery live in ONE function rather than the usual
-- table-trigger-then-delivery-trigger split, because the raw token must reach
-- the Edge Function and is deliberately not stored on the row. A second trigger
-- reading the row back would have nothing to send.
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

  -- No login yet -- a Draft or an un-activated hire. activate-employee will
  -- create the auth user from business_email when the time comes, which is the
  -- existing behaviour and still correct.
  SELECT p.id, u.email
  INTO   v_profile_id, v_auth_email
  FROM   profiles p
  JOIN   auth.users u ON u.id = p.id
  WHERE  p.employee_id = NEW.id
  LIMIT  1;

  IF v_profile_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Already the login. Happens when an admin retypes the same address, and when
  -- this trigger's own confirmation writes business_email into line.
  IF lower(coalesce(v_auth_email, '')) = lower(NEW.business_email) THEN
    UPDATE employee_email_changes
    SET    status = 'superseded', resolved_at = now()
    WHERE  employee_id = NEW.id AND status = 'pending';
    RETURN NEW;
  END IF;

  -- A newer edit invalidates the older link.
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
    -- The row stands and can be re-sent; what must not happen is the edit
    -- succeeding while nobody is ever told the login did not move.
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

COMMENT ON FUNCTION public.trg_employee_email_change() IS
  'Raises a pending login-email change when employees.business_email is edited, '
  'and posts the one-time verification link to the Edge Function. Carries no '
  'permission check of its own: it runs after an UPDATE that employees_update '
  'RLS has already authorised.';

DROP TRIGGER IF EXISTS employees_business_email_change ON public.employees;
CREATE TRIGGER employees_business_email_change
  AFTER UPDATE OF business_email ON public.employees
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_employee_email_change();


-- ── 3. Expiry, and telling somebody ──────────────────────────────────────────
-- An unverified change is the one state where HR and the login disagree with
-- nobody watching. Seven days, then the request lapses and the person who made
-- the edit is notified -- through the existing notifications table, so it
-- reaches them by email on the path that already works.
CREATE OR REPLACE FUNCTION public.expire_employee_email_changes()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row   record;
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT c.id, c.requested_by, c.new_email, c.old_email, e.name
    FROM   employee_email_changes c
    JOIN   employees e ON e.id = c.employee_id
    WHERE  c.status = 'pending'
      AND  c.expires_at < now()
  LOOP
    UPDATE employee_email_changes
    SET    status = 'expired', resolved_at = now()
    WHERE  id = v_row.id;

    IF v_row.requested_by IS NOT NULL THEN
      INSERT INTO notifications (profile_id, title, body, link)
      VALUES (
        v_row.requested_by,
        'Login email change expired for ' || v_row.name,
        'The change to ' || v_row.new_email || ' was never confirmed, so '
        || v_row.name || ' still signs in as ' || v_row.old_email
        || '. Their employee record shows the new address. Re-save the field to '
        || 'send a fresh verification link, or set it back.',
        '/admin/employees'
      );
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END
$fn$;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('expire-employee-email-changes')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-employee-email-changes');

    PERFORM cron.schedule(
      'expire-employee-email-changes',
      '17 2 * * *',
      $job$SELECT public.expire_employee_email_changes();$job$
    );
    RAISE NOTICE 'mig 761: expiry job scheduled daily at 02:17 UTC';
  ELSE
    RAISE NOTICE 'mig 761: pg_cron not enabled — expiry must be run manually';
  END IF;
END
$cron$;


-- ── 4. Applying a verified change ────────────────────────────────────────────
-- Called by the confirm-email-change Edge Function AFTER it has swapped
-- auth.users.email through the admin API. Split this way on purpose: Postgres
-- cannot safely write auth.users itself (GoTrue owns identities, confirmation
-- timestamps and the identities table), and the Edge Function cannot be trusted
-- to decide whether a token was valid. So the database rules on the token and
-- the Edge Function performs the swap.
CREATE OR REPLACE FUNCTION public.claim_email_change_token(p_token text)
RETURNS TABLE (change_id uuid, profile_id uuid, new_email text, employee_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $fn$
DECLARE
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

CREATE OR REPLACE FUNCTION public.finish_email_change(p_change_id uuid, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_error IS NOT NULL THEN
    UPDATE employee_email_changes
    SET    error_message = p_error
    WHERE  id = p_change_id;
    RETURN;
  END IF;

  UPDATE employee_email_changes
  SET    status = 'verified', resolved_at = now(), error_message = NULL
  WHERE  id = p_change_id AND status = 'pending';
END
$fn$;

REVOKE ALL ON FUNCTION public.finish_email_change(uuid, text) FROM PUBLIC, anon, authenticated;


-- ── Assertions ───────────────────────────────────────────────────────────────
-- The failure that matters is the trigger not being attached: business_email
-- would go on being editable and the login would go on not moving, which is
-- exactly today's defect and looks identical to success.
DO $chk$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM   pg_trigger
  WHERE  tgname = 'employees_business_email_change'
    AND  NOT tgisinternal;

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 761 assert: trigger not attached to employees';
  END IF;

  SELECT count(*) INTO v_n
  FROM   pg_policies
  WHERE  schemaname = 'public'
    AND  tablename  = 'employee_email_changes'
    AND  cmd <> 'SELECT';

  IF v_n <> 0 THEN
    RAISE EXCEPTION
      'mig 761 assert: % write policy(ies) on employee_email_changes — the audit '
      'must not be writable from the client', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM app_config
  WHERE  key = 'supabase_functions_url' AND coalesce(value, '') <> '';

  IF v_n = 0 THEN
    RAISE WARNING
      'mig 761: supabase_functions_url is empty in app_config — verification '
      'emails will be skipped until it is set';
  END IF;

  -- Prove the primitives resolve, rather than discovering it when an
  -- administrator saves a form and the trigger throws into their face.
  DECLARE
    v_probe text;
  BEGIN
    -- Under the FUNCTIONS' search_path, not this session's. Without this the
    -- probe fails on any database where pgcrypto sits in extensions and the
    -- deploy session's path is bare public -- i.e. it would abort a migration
    -- that was about to work perfectly.
    EXECUTE 'SET LOCAL search_path = public, extensions';
    SELECT encode(digest(encode(gen_random_bytes(8), 'hex'), 'sha256'), 'hex') INTO v_probe;
    IF v_probe IS NULL OR length(v_probe) <> 64 THEN
      RAISE EXCEPTION 'mig 761 assert: pgcrypto did not produce a sha256 digest';
    END IF;
  EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
    RAISE EXCEPTION
      'mig 761 assert: pgcrypto is not reachable from search_path — no email '
      'change could ever be issued or confirmed on this database';
  END;

  RAISE NOTICE 'mig 761: business_email now drives the login, verified before it takes effect';
END
$chk$;
