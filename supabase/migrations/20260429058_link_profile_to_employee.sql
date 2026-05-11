-- =============================================================================
-- Migration 058: link_profile_to_employee RPC
--
-- Called by the Role Assignments "Invite" button immediately after
-- supabase.auth.signInWithOtp() creates the auth user.
--
-- What it does:
--   1. Looks up the auth.users row by email to get the user uuid
--   2. Finds the matching employees row by business_email
--   3. Sets profiles.employee_id = employee.id  (links them)
--   4. Grants the ESS role if not already present
--
-- Returns: { ok: true } on success, { ok: false, reason: '...' } on failure.
-- Never raises — caller always gets a JSONB result it can inspect.
--
-- Security: SECURITY DEFINER so it can read auth.users.
--           Only callable by admins or users with security.manage_roles.
-- =============================================================================

CREATE OR REPLACE FUNCTION link_profile_to_employee(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id    uuid;
  v_profile_id uuid;
  v_emp_id     uuid;
  v_ess_role   uuid;
BEGIN
  -- ── Permission check ────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('security.manage_roles')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  -- ── 1. Find the auth user ────────────────────────────────────────────────
  SELECT id INTO v_user_id
  FROM   auth.users
  WHERE  lower(email) = lower(p_email)
  LIMIT  1;

  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'auth user not found for ' || p_email ||
                ' — the invite email may not have been delivered yet'
    );
  END IF;

  -- ── 2. Find (or wait for) the profile row ────────────────────────────────
  -- handle_new_user() fires on auth.users INSERT, but may not have committed
  -- yet. Give it one retry with a short wait.
  SELECT id INTO v_profile_id FROM profiles WHERE id = v_user_id;

  IF v_profile_id IS NULL THEN
    PERFORM pg_sleep(0.5);
    SELECT id INTO v_profile_id FROM profiles WHERE id = v_user_id;
  END IF;

  IF v_profile_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'profile row not yet created for user ' || v_user_id ||
                ' — try again in a moment'
    );
  END IF;

  -- ── 3. Find the employee by business_email ───────────────────────────────
  SELECT id INTO v_emp_id
  FROM   employees
  WHERE  lower(business_email) = lower(p_email)
    AND  status = 'Active'
  LIMIT  1;

  IF v_emp_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'no active employee found with business_email = ' || p_email
    );
  END IF;

  -- ── 4. Link profile → employee ───────────────────────────────────────────
  UPDATE profiles
  SET    employee_id = v_emp_id,
         updated_at  = now()
  WHERE  id = v_profile_id
    AND  (employee_id IS NULL OR employee_id = v_emp_id);

  -- ── 5. Grant ESS role if not already present ─────────────────────────────
  SELECT id INTO v_ess_role FROM roles WHERE code = 'ess' LIMIT 1;

  IF v_ess_role IS NOT NULL THEN
    INSERT INTO user_roles (profile_id, role_id, assignment_source, granted_at, updated_at)
    VALUES (v_profile_id, v_ess_role, 'invite', now(), now())
    ON CONFLICT (profile_id, role_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

COMMENT ON FUNCTION link_profile_to_employee(text) IS
  'Links a newly-invited auth user to their employee record and grants the ESS '
  'role. Called by the Role Assignments Invite button after signInWithOtp(). '
  'Returns {ok, reason} JSONB — never raises.';


-- ════════════════════════════════════════════════════════════════════════════
-- Also patch handle_new_user() to auto-link employee on signup
-- if the email already matches an employees.business_email row.
-- This handles cases where the admin sets a password directly rather
-- than using the Invite button.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_new_user() IS
  'Fires on auth.users INSERT. Creates a bare profile, then auto-links to an '
  'employee record if business_email matches, and grants ESS automatically.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname FROM pg_proc
WHERE  proname IN ('link_profile_to_employee', 'handle_new_user');
