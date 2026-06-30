-- Migration 571: Complete admin password reset setup
-- (audit table + RPCs that didn't apply in 570 due to partial failure)

-- ── 1. Audit table ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS admin_password_resets (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id          uuid        NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name        text,
  target_profile_id uuid        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  target_email      text        NOT NULL,
  target_name       text,
  action            text        NOT NULL CHECK (action IN ('set_password', 'send_reset_link')),
  force_change      boolean     NOT NULL DEFAULT true,
  success           boolean     NOT NULL DEFAULT false,
  error_message     text,
  ip_address        text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_password_resets_actor_idx
  ON admin_password_resets (actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_password_resets_target_idx
  ON admin_password_resets (target_profile_id, created_at DESC);

ALTER TABLE admin_password_resets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS apr_select ON admin_password_resets;
CREATE POLICY apr_select ON admin_password_resets FOR SELECT
  USING (
    actor_id = auth.uid()
    OR user_can('sec_password_reset', 'view', NULL)
  );

-- ── 2. can_reset_password RPC ─────────────────────────────────────────────────

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

  v_actor_is_super  := is_super_admin();

  v_target_is_super := EXISTS (
    SELECT 1 FROM user_roles pr JOIN roles r ON r.id = pr.role_id
    WHERE  pr.profile_id = p_target_profile_id AND r.code = 'super_admin'
  );
  IF v_target_is_super AND NOT v_actor_is_super THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'You cannot reset the password of a super-admin.');
  END IF;

  v_target_is_admin := EXISTS (
    SELECT 1 FROM user_roles pr JOIN roles r ON r.id = pr.role_id
    WHERE  pr.profile_id = p_target_profile_id AND r.code = 'admin'
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

-- ── 3. get_password_reset_audit RPC ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_password_reset_audit(p_limit int DEFAULT 50)
RETURNS TABLE (
  id            uuid,
  actor_name    text,
  target_name   text,
  target_email  text,
  action        text,
  force_change  boolean,
  success       boolean,
  error_message text,
  created_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT (is_super_admin() OR user_can('sec_password_reset', 'view', NULL)) THEN
    RAISE EXCEPTION 'get_password_reset_audit: insufficient permissions';
  END IF;

  RETURN QUERY
  SELECT r.id, r.actor_name, r.target_name, r.target_email,
         r.action, r.force_change, r.success, r.error_message, r.created_at
  FROM   admin_password_resets r
  ORDER  BY r.created_at DESC
  LIMIT  p_limit;
END;
$fn$;

REVOKE ALL    ON FUNCTION get_password_reset_audit(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_password_reset_audit(int) TO authenticated;

-- ── Verification ──────────────────────────────────────────────────────────────

DO $fn$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'admin_password_resets'),
    'ABORT: admin_password_resets table not found';
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_reset_password'),
    'ABORT: can_reset_password function not found';
  RAISE NOTICE 'Migration 571: admin password reset RPCs — OK';
END;
$fn$;
