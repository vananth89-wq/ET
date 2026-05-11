-- =============================================================================
-- Migration 144: Super admin bypass for get_my_permissions() and
--                get_target_population()
--
-- CONTEXT
-- ═══════
-- Migration 112 created the super_admins UUID allowlist and is_super_admin().
-- Migration 113 wired is_super_admin() into user_can() Path A — so super admins
-- already bypass every RLS policy at the database layer.
--
-- PROBLEM
-- ═══════
-- The frontend permission layer has TWO separate functions:
--
--   get_my_permissions()    — called once on login; result cached in
--                             PermissionContext as a Set<string>.
--                             ProtectedRoute checks requiredPermission against
--                             this set before rendering any page.
--
--   get_target_population() — called per module+action to determine which
--                             employee records the user's UI should show.
--
-- Neither function called is_super_admin() before this migration.  A super
-- admin whose role has no permission sets assigned would therefore:
--   • get_my_permissions()    → returns '{}'  → ProtectedRoute blocks every page
--   • get_target_population() → returns mode:'none' → UI shows empty tables
--
-- Even though user_can() (RLS) returns true for them, the UI never fires the
-- queries — it refuses to render the pages at all.
--
-- FIX
-- ═══
-- Add an is_super_admin() short-circuit at the top of each function:
--
--   get_my_permissions()    → return codes of ALL active permissions
--   get_target_population() → return mode:'all'  (unrestricted scope)
--
-- This mirrors exactly what user_can() does:  super admin → full access,
-- database layer AND frontend layer, with a single UUID allowlist as the
-- sole gate.
--
-- WHAT DOES NOT CHANGE
-- ════════════════════
--   user_can()         — unchanged (bypass already in place since mig 113)
--   is_super_admin()   — unchanged (reads super_admins table)
--   super_admins table — unchanged (service_role only writes)
--   All RLS policies   — unchanged (still call user_can())
--   Normal admin role  — unchanged (goes through permission matrix as before)
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_my_permissions() — add super admin short-circuit
--
-- Super admin → return every active permission code in the system.
-- Normal user → unchanged join chain.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- ── Super admin: return all active permission codes ───────────────────────
  --   Mirrors user_can() Path A — UUID allowlist, cannot be misconfigured.
  IF is_super_admin() THEN
    RETURN COALESCE(
      (SELECT array_agg(DISTINCT code) FROM permissions WHERE action IS NOT NULL),
      '{}'
    );
  END IF;

  -- ── Normal path: permission_set_assignments → items → permissions ─────────
  RETURN COALESCE(
    (
      SELECT array_agg(DISTINCT p.code)
      FROM   user_roles                ur
      JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
      JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
      JOIN   permissions                p   ON p.id                  = psi.permission_id
      WHERE  ur.profile_id = auth.uid()
        AND  ur.is_active  = true
        AND  (ur.expires_at IS NULL OR ur.expires_at > now())
    ),
    '{}'
  );
END;
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes for the current user. '
  'Super admin (is_super_admin()): returns every active permission — mirrors user_can() Path A. '
  'Normal user: permission_set_assignments → permission_set_items → permissions. '
  'Called once on login by PermissionContext; cached client-side in a Set.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_target_population() — add super admin short-circuit
--
-- Super admin → mode:'all' immediately — no scoping, see every employee.
-- Normal user → unchanged logic (Paths A–D).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_target_population(
  p_module text,
  p_action text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_employee_id  uuid;
  v_has_everyone boolean := false;
  v_has_perm     boolean := false;
  v_ids          uuid[];
BEGIN

  -- ── Super admin: unrestricted scope — see everyone ────────────────────────
  IF is_super_admin() THEN
    RETURN jsonb_build_object('mode', 'all');
  END IF;

  -- ── Does the user have ANY permission for this module+action? ─────────────
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    WHERE  ur.profile_id = v_uid
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code        = p_module
      AND  p.action      = p_action
  ) INTO v_has_perm;

  IF NOT v_has_perm THEN
    RETURN jsonb_build_object('mode', 'none', 'reason', 'no_permission');
  END IF;

  -- ── Does any assignment point to an 'everyone' target group? ─────────────
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    JOIN   target_groups              tg  ON tg.id                 = psa.target_group_id
    WHERE  ur.profile_id = v_uid
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code        = p_module
      AND  p.action      = p_action
      AND  tg.scope_type = 'everyone'
  ) INTO v_has_everyone;

  IF v_has_everyone THEN
    RETURN jsonb_build_object('mode', 'all');
  END IF;

  -- ── Resolve scoped target groups to employee UUIDs ────────────────────────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  WITH target_groups_for_user AS (
    SELECT DISTINCT tg.id AS group_id, tg.scope_type
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    JOIN   target_groups              tg  ON tg.id                 = psa.target_group_id
    WHERE  ur.profile_id = v_uid
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code        = p_module
      AND  p.action      = p_action
      AND  tg.scope_type <> 'everyone'
  ),
  resolved AS (
    -- custom — pre-computed cache
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type = 'custom'

    UNION

    -- self
    SELECT v_employee_id AS emp_id
    FROM   target_groups_for_user tgfu
    WHERE  tgfu.scope_type = 'self'
      AND  v_employee_id IS NOT NULL

    UNION

    -- direct_l1
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.manager_id = v_employee_id
                       AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'direct_l1'

    UNION

    -- direct_l2
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.deleted_at IS NULL
                       AND (
                         e.manager_id = v_employee_id
                         OR EXISTS (
                           SELECT 1 FROM employees l1
                           WHERE  l1.id         = e.manager_id
                             AND  l1.manager_id = v_employee_id
                             AND  l1.deleted_at IS NULL
                         )
                       )
    WHERE  tgfu.scope_type = 'direct_l2'

    UNION

    -- same_department
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    CROSS  JOIN (SELECT dept_id FROM employees WHERE id = v_employee_id) me
    JOIN   employees e ON e.dept_id    = me.dept_id
                       AND e.dept_id   IS NOT NULL
                       AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'same_department'

    UNION

    -- same_country
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    CROSS  JOIN (SELECT work_country FROM employees WHERE id = v_employee_id) me
    JOIN   employees e ON e.work_country  = me.work_country
                       AND e.work_country IS NOT NULL
                       AND e.deleted_at   IS NULL
    WHERE  tgfu.scope_type = 'same_country'
  )
  SELECT array_agg(DISTINCT emp_id) INTO v_ids FROM resolved;

  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RETURN jsonb_build_object('mode', 'none', 'reason', 'empty_group');
  END IF;

  RETURN jsonb_build_object('mode', 'scoped', 'ids', to_jsonb(v_ids));
END;
$$;

COMMENT ON FUNCTION get_target_population(text, text) IS
  'Returns the target population for the current user on a given module+action. '
  'Super admin (is_super_admin()): returns mode:all immediately — unrestricted scope. '
  'Normal user: reads permission_set_assignments → scope-type resolution. '
  'mode=all: everyone scope. mode=scoped: restricted ids. mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm both functions now reference is_super_admin()
SELECT
  proname                                        AS function_name,
  prosrc LIKE '%is_super_admin%'                 AS has_super_admin_bypass,
  prosrc NOT LIKE '%has_role%'                   AS no_legacy_has_role
FROM pg_proc
WHERE proname IN ('get_my_permissions', 'get_target_population', 'user_can')
ORDER BY proname;

-- Expected for all three:
--   has_super_admin_bypass = true
--   no_legacy_has_role     = true

-- =============================================================================
-- END OF MIGRATION 144
--
-- Super admin coverage is now complete across all three layers:
--
--   Layer               Function                  Since
--   ──────────────────  ────────────────────────  ───────────
--   RLS (DB)            user_can()                Migration 113
--   UI gates            get_my_permissions()      Migration 144 ← this file
--   Data population     get_target_population()   Migration 144 ← this file
--
-- A super admin can now always:
--   • Log in and see all pages (ProtectedRoute passes)
--   • Query all employee data (user_can() passes RLS)
--   • See all employees in every list (get_target_population → mode:all)
--   • Reconfigure the Permission Matrix regardless of set assignments
-- =============================================================================
