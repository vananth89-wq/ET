-- =============================================================================
-- Migration 577: Fix link_profile_to_employee — column "active" does not exist
--
-- The live DB version of this function references employees.active, which no
-- longer exists (employees uses employees.status = 'Active'). This restores
-- the correct definition from mig 058.
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
  -- ── Permission check ────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('security.manage_roles')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  -- ── 1. Find the auth user ────────────────────────────────────────────────────
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

  -- ── 2. Find (or wait for) the profile row ───────────────────────────────────
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

  -- ── 3. Find the employee by business_email ───────────────────────────────────
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

  -- ── 4. Link profile → employee ───────────────────────────────────────────────
  UPDATE profiles
  SET    employee_id = v_emp_id,
         updated_at  = now()
  WHERE  id = v_profile_id
    AND  (employee_id IS NULL OR employee_id = v_emp_id);

  -- ── 5. Grant ESS role if not already present ─────────────────────────────────
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

-- Verification
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'link_profile_to_employee'),
    'ABORT: link_profile_to_employee not found';
  RAISE NOTICE 'Migration 577: link_profile_to_employee fixed — OK';
END;
$$;
