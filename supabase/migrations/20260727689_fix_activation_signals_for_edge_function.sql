-- =============================================================================
-- Migration 689 — Fix activation signals for Edge Function flow
--
-- CONTEXT
-- ═══════
-- Path-2 activation (via activate-employee Edge Function) creates the auth
-- user *immediately* when admin clicks Activate. The handle_new_user trigger
-- fires instantly and stamps invite_accepted_at + marks employee_invites row
-- as 'accepted'. That's semantically wrong — those signals should mean
-- "user has actually signed in", not "auth account was provisioned".
--
-- Downstream effect: resend_hire_invite guards on "profile exists + linked"
-- which now happens immediately, so ANY resend attempt errors out with
-- "employee already has an active auth account".
--
-- FIX
-- ═══
-- 1. handle_new_user trigger: stop stamping invite_accepted_at and stop
--    marking employee_invites as accepted. Just create profile + link + ESS.
--
-- 2. New trigger on auth.users UPDATE: when last_sign_in_at transitions from
--    NULL to a value, stamp invite_accepted_at and mark invite as accepted.
--    That's the real "user has signed in" signal.
--
-- 3. resend_hire_invite guard: use last_sign_in_at IS NOT NULL instead of
--    "profile exists + linked" to detect real sign-ins.
--
-- IDEMPOTENT: safe to re-run.
-- =============================================================================


-- ── 1. Simplify handle_new_user (creation only, no "accepted" side-effects) ──

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_emp_id   uuid;
  v_ess_role uuid;
BEGIN
  -- Create bare profile
  INSERT INTO public.profiles (id, is_active, created_at, updated_at)
  VALUES (NEW.id, true, NOW(), NOW())
  ON CONFLICT (id) DO NOTHING;

  -- Auto-link to employee if business_email matches
  SELECT id INTO v_emp_id
  FROM   public.employees
  WHERE  lower(business_email) = lower(NEW.email)
    AND  status = 'Active'
    AND  deleted_at IS NULL
  LIMIT  1;

  IF v_emp_id IS NOT NULL THEN
    UPDATE public.profiles
    SET    employee_id = v_emp_id,
           updated_at  = now()
    WHERE  id = NEW.id AND employee_id IS NULL;

    -- Grant ESS automatically
    SELECT id INTO v_ess_role FROM public.roles WHERE code = 'ess' LIMIT 1;
    IF v_ess_role IS NOT NULL THEN
      INSERT INTO public.user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
      VALUES (NEW.id, v_ess_role, 'auto', now(), now())
      ON CONFLICT (profile_id, role_id) DO NOTHING;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'Fires on auth.users INSERT. Creates a bare profile, auto-links to '
  'employee if business_email matches, and grants ESS. Does NOT stamp '
  'invite_accepted_at — that is done by handle_user_sign_in on real sign-in. '
  'Mig 689.';


-- ── 2. New trigger for real sign-in (stamps invite_accepted_at) ──────────────

CREATE OR REPLACE FUNCTION public.handle_user_sign_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_emp_id uuid;
BEGIN
  -- Only act when last_sign_in_at transitions from NULL to a value
  IF (OLD.last_sign_in_at IS NULL) AND (NEW.last_sign_in_at IS NOT NULL) THEN

    -- Find the linked employee via profiles
    SELECT p.employee_id INTO v_emp_id
    FROM   public.profiles p
    WHERE  p.id = NEW.id
      AND  p.employee_id IS NOT NULL;

    IF v_emp_id IS NOT NULL THEN
      -- Stamp invite_accepted_at on the employee record
      UPDATE public.employees
      SET    invite_accepted_at = now(),
             updated_at         = now()
      WHERE  id = v_emp_id
        AND  invite_sent_at IS NOT NULL
        AND  invite_accepted_at IS NULL;

      -- Mark the most recent 'sent' invite row as accepted
      UPDATE public.employee_invites
      SET    status     = 'accepted',
             updated_at = now()
      WHERE  id = (
        SELECT id FROM public.employee_invites
        WHERE  employee_id = v_emp_id
          AND  status = 'sent'
        ORDER  BY sent_at DESC
        LIMIT  1
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_user_sign_in() IS
  'Fires on auth.users UPDATE. When last_sign_in_at transitions from NULL '
  'to a value, stamps employees.invite_accepted_at and marks the latest '
  'employee_invites row as accepted. Mig 689.';

-- Install the trigger (idempotent)
DROP TRIGGER IF EXISTS trg_on_auth_user_sign_in ON auth.users;
CREATE TRIGGER trg_on_auth_user_sign_in
  AFTER UPDATE OF last_sign_in_at ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_user_sign_in();


-- ── 3. Update resend_hire_invite guard ───────────────────────────────────────

CREATE OR REPLACE FUNCTION resend_hire_invite(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_emp          employees%ROWTYPE;
  v_next_attempt int;
  v_has_signed_in boolean;
BEGIN
  -- Permission gate
  IF NOT (user_can('hire_employee', 'edit', NULL) OR is_super_admin()) THEN
    RAISE EXCEPTION 'resend_hire_invite: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Load employee
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'resend_hire_invite: employee % not found', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Must be Active
  IF v_emp.status != 'Active' THEN
    RAISE EXCEPTION 'resend_hire_invite: employee is not Active (status: %)',
                    v_emp.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Must have a business email
  IF v_emp.business_email IS NULL OR v_emp.business_email = '' THEN
    RAISE EXCEPTION 'resend_hire_invite: employee has no business email'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Mig 689 CHANGE: guard on real sign-in, not on profile existence ────────
  -- The old check ("profile exists + linked") is broken now because the
  -- activate-employee Edge Function creates the auth user immediately,
  -- which fires handle_new_user and creates the profile. We now check
  -- auth.users.last_sign_in_at IS NOT NULL — the real "has actually
  -- signed in" signal.
  SELECT EXISTS (
    SELECT 1 FROM auth.users
    WHERE  lower(email) = lower(v_emp.business_email)
      AND  last_sign_in_at IS NOT NULL
  ) INTO v_has_signed_in;

  IF v_has_signed_in THEN
    RAISE EXCEPTION
      'resend_hire_invite: employee has already signed in — resend not needed'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Record the resend attempt
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  RETURN jsonb_build_object(
    'ok',    true,
    'email', v_emp.business_email,
    'name',  v_emp.name,
    'attempt_no', v_next_attempt
  );
END;
$$;

REVOKE ALL    ON FUNCTION resend_hire_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resend_hire_invite(uuid) TO authenticated;

COMMENT ON FUNCTION resend_hire_invite(uuid) IS
  'Guard + audit for re-sending a hire invite. Mig 689: guard now uses '
  'auth.users.last_sign_in_at IS NOT NULL (real sign-in) instead of '
  'profile-exists-and-linked (which now happens on admin activation).';


-- ── 4. Backfill: reset invite_accepted_at for employees where user has NOT signed in ──
-- If any employees got a false invite_accepted_at stamp (from the buggy trigger
-- between when we shipped the Edge Function and this fix), clear it so the
-- state reflects reality.
UPDATE public.employees e
SET    invite_accepted_at = NULL,
       updated_at         = now()
WHERE  e.invite_accepted_at IS NOT NULL
  AND  NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE  lower(u.email) = lower(e.business_email)
      AND  u.last_sign_in_at IS NOT NULL
  );

-- Same for employee_invites — flip 'accepted' back to 'sent' when the user
-- hasn't actually signed in.
UPDATE public.employee_invites ei
SET    status     = 'sent',
       updated_at = now()
FROM   public.employees e
WHERE  ei.employee_id = e.id
  AND  ei.status = 'accepted'
  AND  NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE  lower(u.email) = lower(e.business_email)
      AND  u.last_sign_in_at IS NOT NULL
  );


-- ── Verification ─────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_on_auth_user_sign_in'
      AND tgrelid = 'auth.users'::regclass
  ) INTO v_ok;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'ABORT: trg_on_auth_user_sign_in not installed';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'handle_user_sign_in'
  ) INTO v_ok;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'ABORT: handle_user_sign_in function missing';
  END IF;

  RAISE NOTICE 'Migration 689 verified: sign-in trigger installed, resend guard fixed.';
END $$;
