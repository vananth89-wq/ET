-- Migration 578: Fix can_reset_password — profile_roles does not exist
-- Replace all profile_roles references with user_roles (dropped in mig 146)

CREATE OR REPLACE FUNCTION can_reset_password(p_target_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_actor_id        uuid    := auth.uid();
  v_target_email    text;
  v_target_auth_id  uuid;
  v_target_name     text;
  v_actor_name      text;
  v_target_is_super boolean;
  v_actor_is_super  boolean;
  v_target_is_admin boolean;
BEGIN
  IF NOT (is_super_admin() OR user_can('sec_password_reset', 'edit', NULL)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'You do not have permission to reset passwords.');
  END IF;

  SELECT au.email, au.id
  INTO   v_target_email, v_target_auth_id
  FROM   auth.users au
  WHERE  au.id = p_target_profile_id;

  IF v_target_auth_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'Target user has no auth account — send them a welcome invite first.');
  END IF;

  SELECT e.name INTO v_target_name
  FROM   profiles p JOIN employees e ON e.id = p.employee_id
  WHERE  p.id = p_target_profile_id;

  SELECT e.name INTO v_actor_name
  FROM   profiles p JOIN employees e ON e.id = p.employee_id
  WHERE  p.id = v_actor_id;

  v_actor_is_super := is_super_admin();

  v_target_is_super := EXISTS (
    SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
    WHERE  ur.profile_id = p_target_profile_id AND r.code = 'super_admin'
  );
  IF v_target_is_super AND NOT v_actor_is_super THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'You cannot reset the password of a super-admin.');
  END IF;

  v_target_is_admin := EXISTS (
    SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
    WHERE  ur.profile_id = p_target_profile_id AND r.code = 'admin'
  );
  IF v_target_is_admin AND NOT v_actor_is_super THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'You cannot reset the password of another admin. Contact a super-admin.');
  END IF;

  IF p_target_profile_id = v_actor_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'Use the account menu to change your own password.');
  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'target_email',   v_target_email,
    'target_auth_id', v_target_auth_id,
    'target_name',    v_target_name,
    'actor_name',     v_actor_name
  );
END;
$fn$;

REVOKE ALL    ON FUNCTION can_reset_password(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION can_reset_password(uuid) TO authenticated;

DO $fn$
BEGIN
  RAISE NOTICE 'Migration 578: can_reset_password fixed (profile_roles → user_roles) — OK';
END;
$fn$;
