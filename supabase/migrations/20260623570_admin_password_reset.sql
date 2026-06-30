-- =============================================================================
-- Migration 570: Admin Password Reset
SET search_path TO public;
--
-- Adds the ability for authorised admins to reset another user's password
-- directly (set a temporary password) or trigger a recovery email.
--
-- WHAT THIS ADDS
-- ──────────────
-- 1. sec_password_reset module + 2 permissions:
--      sec_password_reset.view   — see the page + audit log
--      sec_password_reset.edit  — actually perform a reset
--
-- 2. admin_password_resets audit table — immutable log of every reset action.
--
-- 3. can_reset_password(p_target_profile_id) RPC — called by the Edge Function
--    to validate the caller has permission AND that the target is not a
--    higher-privileged user (privilege escalation guard).
--    Returns: { ok, reason, target_email, target_auth_id }
--
-- 4. get_password_reset_audit(p_limit) RPC — returns recent resets for the
--    admin UI audit log panel.
-- =============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Module
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO modules (code, name, active, sort_order)
VALUES ('sec_password_reset', 'Password Reset', true, 310)
ON CONFLICT (code) DO UPDATE
  SET name       = EXCLUDED.name,
      active     = EXCLUDED.active,
      sort_order = EXCLUDED.sort_order;


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Expand action check to allow 'reset', then insert permissions
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE permissions DROP CONSTRAINT IF EXISTS permissions_action_check;
ALTER TABLE permissions ADD CONSTRAINT permissions_action_check
  CHECK (action IN ('view', 'create', 'edit', 'delete', 'history', 'lookup',
                    'view_all_pending', 'edit_all_pending',
                    'bulk_import', 'bulk_export',
                    'view_inactive', 'reassign'));

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  p.code, p.name, p.description, m.id, p.action
FROM (VALUES
  ('sec_password_reset.view',
   'View Password Reset',
   'Access the Admin Password Reset page and view the audit log.',
   'view'),
  ('sec_password_reset.edit',
   'Reset User Password',
   'Set a temporary password or send a password-reset link for another user. '
   'Cannot be used on super-admins or users with higher privilege.',
   'edit')
) AS p(code, name, description, action)
JOIN modules m ON m.code = 'sec_password_reset'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      module_id   = EXCLUDED.module_id,
      action      = EXCLUDED.action;

-- No default grants — assign via the Permission Matrix UI.
-- (role_permissions was dropped in mig 146; grants now live in permission_set_items)


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Audit table
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS admin_password_resets (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- who did the reset
  actor_id          uuid        NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name        text,                        -- snapshot at time of action
  -- who was reset
  target_profile_id uuid        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  target_email      text        NOT NULL,
  target_name       text,                        -- snapshot at time of action
  -- what happened
  action            text        NOT NULL CHECK (action IN ('set_password', 'send_reset_link')),
  force_change      boolean     NOT NULL DEFAULT true,
  -- outcome
  success           boolean     NOT NULL DEFAULT false,
  error_message     text,
  -- metadata
  ip_address        text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE admin_password_resets IS
  'Immutable audit log of every admin-initiated password reset. Append-only.';

CREATE INDEX IF NOT EXISTS admin_password_resets_actor_idx
  ON admin_password_resets (actor_id, created_at DESC);

CREATE INDEX IF NOT EXISTS admin_password_resets_target_idx
  ON admin_password_resets (target_profile_id, created_at DESC);

ALTER TABLE admin_password_resets ENABLE ROW LEVEL SECURITY;

-- Admins with the view permission can read; actors can always see their own entries
DROP POLICY IF EXISTS apr_select ON admin_password_resets;
CREATE POLICY apr_select ON admin_password_resets FOR SELECT
  USING (
    actor_id = auth.uid()
    OR user_can('sec_password_reset', 'view', NULL)
  );

-- Only the Edge Function (service role, bypasses RLS) may INSERT
-- No UPDATE or DELETE — immutable audit log


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. can_reset_password RPC — permission + privilege-escalation guard
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION can_reset_password(p_target_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id        uuid := auth.uid();
  v_target_email    text;
  v_target_auth_id  uuid;
  v_target_name     text;
  v_actor_name      text;
  v_target_is_super boolean;
  v_actor_is_super  boolean;
  v_target_is_admin boolean;
BEGIN
  -- ── 1. Permission check ────────────────────────────────────────────────
  IF NOT (is_super_admin() OR user_can('sec_password_reset', 'edit', NULL)) THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'You do not have permission to reset passwords.'
    );
  END IF;

  -- ── 2. Target must exist and have an auth account ─────────────────────
  SELECT au.email, au.id
  INTO   v_target_email, v_target_auth_id
  FROM   auth.users au
  WHERE  au.id = p_target_profile_id;

  IF v_target_auth_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'Target user has no auth account — send them a welcome invite first.'
    );
  END IF;

  -- ── 3. Resolve names for audit log ────────────────────────────────────
  SELECT e.name INTO v_target_name
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = p_target_profile_id;

  SELECT e.name INTO v_actor_name
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_actor_id;

  -- ── 4. Privilege escalation guard ─────────────────────────────────────
  -- Super admins can reset anyone. Non-super-admins cannot reset super admins
  -- or other admins (to prevent privilege escalation).
  v_actor_is_super  := is_super_admin();
  v_target_is_super := EXISTS (
    SELECT 1 FROM profile_roles pr
    JOIN   roles r ON r.id = pr.role_id
    WHERE  pr.profile_id = p_target_profile_id
      AND  r.code = 'super_admin'
  );

  IF v_target_is_super AND NOT v_actor_is_super THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'You cannot reset the password of a super-admin.'
    );
  END IF;

  -- Non-super-admins also cannot reset other admins
  v_target_is_admin := EXISTS (
    SELECT 1 FROM profile_roles pr
    JOIN   roles r ON r.id = pr.role_id
    WHERE  pr.profile_id = p_target_profile_id
      AND  r.code = 'admin'
  );

  IF v_target_is_admin AND NOT v_actor_is_super THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'You cannot reset the password of another admin. Contact a super-admin.'
    );
  END IF;

  -- ── 5. Cannot reset your own password via this tool ───────────────────
  IF p_target_profile_id = v_actor_id THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'Use the account menu to change your own password.'
    );
  END IF;

  -- ── 6. All checks passed ───────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',              true,
    'target_email',    v_target_email,
    'target_auth_id',  v_target_auth_id,
    'target_name',     v_target_name,
    'actor_name',      v_actor_name
  );
END;
$$;

COMMENT ON FUNCTION can_reset_password(uuid) IS
  'Called by the admin-password-reset Edge Function to validate the caller has '
  'sec_password_reset.edit permission and that the target is not higher-privileged. '
  'Returns { ok, reason, target_email, target_auth_id, target_name, actor_name }.';

REVOKE ALL   ON FUNCTION can_reset_password(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION can_reset_password(uuid) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. get_password_reset_audit RPC — for the admin UI audit panel
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_password_reset_audit(p_limit int DEFAULT 50)
RETURNS TABLE (
  id                uuid,
  actor_name        text,
  target_name       text,
  target_email      text,
  action            text,
  force_change      boolean,
  success           boolean,
  error_message     text,
  created_at        timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (is_super_admin() OR user_can('sec_password_reset', 'view', NULL)) THEN
    RAISE EXCEPTION 'get_password_reset_audit: insufficient permissions';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.actor_name,
    r.target_name,
    r.target_email,
    r.action,
    r.force_change,
    r.success,
    r.error_message,
    r.created_at
  FROM admin_password_resets r
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL   ON FUNCTION get_password_reset_audit(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_password_reset_audit(int) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM modules      WHERE code = 'sec_password_reset'),
    'ABORT: sec_password_reset module not found';
  ASSERT EXISTS (SELECT 1 FROM permissions  WHERE code = 'sec_password_reset.edit'),
    'ABORT: sec_password_reset.edit permission not found';
  ASSERT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_name = 'admin_password_resets'),
    'ABORT: admin_password_resets table not found';
  RAISE NOTICE 'Migration 570: admin password reset — OK';
END;
$$;
