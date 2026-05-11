-- =============================================================================
-- Migration 113: Wire is_super_admin() into user_can() Path A
--
-- ONE LINE CHANGE
-- ───────────────
-- Path A in user_can() changes from:
--   IF has_role('admin') THEN RETURN true; END IF;
-- to:
--   IF is_super_admin() THEN RETURN true; END IF;
--
-- Everything else in user_can() is identical to migration 107:
--   Path B — admin module (p_owner IS NULL)
--   Path C — self short-circuit
--   Path D — scope-aware EV path with target_group branching
--   Join chain — user_roles → permission_set_assignments → permission_set_items
--             → permissions → modules (unchanged from migration 107)
--
-- WHY THIS MATTERS
-- ────────────────
-- has_role('admin') checked the user_roles table — it was a role-based bypass,
-- invisible to the permission matrix, and fragile if the admin role row was
-- missing / inactive / expired.
--
-- is_super_admin() checks the super_admins UUID allowlist (migration 112):
--   - Not a role — cannot be accidentally removed from user_roles
--   - Only service_role can add / remove entries
--   - The admin role now goes through Paths B / C / D like every other role
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
--   All RLS policies           — unchanged (still call user_can())
--   get_my_permissions()       — unchanged
--   get_target_population()    — unchanged
--   permission_set schema      — unchanged
--   admin role + permission set — unchanged (admin still has System Admin set)
-- =============================================================================


CREATE OR REPLACE FUNCTION user_can(
  p_module text,
  p_action text,
  p_owner  uuid      -- employee_id of the record owner; NULL = admin module
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_employee_id uuid;
  v_result      boolean := false;
BEGIN

  -- ── Path A: Super admin bypass ────────────────────────────────────────────
  --   Reads super_admins UUID allowlist (migration 112).
  --   Not role-based — cannot expire or be accidentally removed via user_roles.
  --   Only service_role can add / remove super admins.
  IF is_super_admin() THEN RETURN true; END IF;

  -- ── Path B: Admin-module (no target scoping) ─────────────────────────────
  --   p_owner = NULL for tables like departments, picklists.
  --   Admin permissions live in sets like any other — no target_group filter.
  IF p_owner IS NULL THEN
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
    ) INTO v_result;
    RETURN COALESCE(v_result, false);
  END IF;

  -- ── Resolve caller's employee_id ─────────────────────────────────────────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- ── Path C: Self short-circuit ────────────────────────────────────────────
  --   p_owner is the caller → verify they hold the permission, skip group check.
  IF p_owner = v_employee_id THEN
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
    ) INTO v_result;
    RETURN COALESCE(v_result, false);
  END IF;

  -- ── Path D: EV path — scope_type-aware permission + membership check ──────
  --   target_group_id comes from permission_set_assignments.
  --   Scope logic (everyone/custom/direct_l1/direct_l2/dept/country) unchanged.
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
      AND  (

        -- ── everyone / custom — pre-computed cache ────────────────────────
        (
          tg.scope_type IN ('everyone', 'custom')
          AND EXISTS (
            SELECT 1 FROM target_group_members tgm
            WHERE  tgm.group_id  = tg.id
              AND  tgm.member_id = p_owner
          )
        )

        -- ── direct_l1 — p_owner's manager = current user ─────────────────
        OR (
          tg.scope_type = 'direct_l1'
          AND EXISTS (
            SELECT 1 FROM employees e
            WHERE  e.id         = p_owner
              AND  e.manager_id = v_employee_id
              AND  e.deleted_at IS NULL
          )
        )

        -- ── direct_l2 — L1 or skip-level (L2) ────────────────────────────
        OR (
          tg.scope_type = 'direct_l2'
          AND EXISTS (
            SELECT 1 FROM employees e
            WHERE  e.id         = p_owner
              AND  e.deleted_at IS NULL
              AND  (
                e.manager_id = v_employee_id
                OR EXISTS (
                  SELECT 1 FROM employees l1
                  WHERE  l1.id         = e.manager_id
                    AND  l1.manager_id = v_employee_id
                    AND  l1.deleted_at IS NULL
                )
              )
          )
        )

        -- ── same_department ───────────────────────────────────────────────
        OR (
          tg.scope_type = 'same_department'
          AND EXISTS (
            SELECT 1
            FROM   employees e_owner
            JOIN   employees e_me ON e_me.id = v_employee_id
            WHERE  e_owner.id      = p_owner
              AND  e_owner.dept_id = e_me.dept_id
              AND  e_owner.dept_id IS NOT NULL
              AND  e_owner.deleted_at IS NULL
          )
        )

        -- ── same_country ──────────────────────────────────────────────────
        OR (
          tg.scope_type = 'same_country'
          AND EXISTS (
            SELECT 1
            FROM   employees e_owner
            JOIN   employees e_me ON e_me.id = v_employee_id
            WHERE  e_owner.id           = p_owner
              AND  e_owner.work_country  = e_me.work_country
              AND  e_owner.work_country  IS NOT NULL
              AND  e_owner.deleted_at   IS NULL
          )
        )

      )
  ) INTO v_result;

  RETURN COALESCE(v_result, false);
END;
$$;

COMMENT ON FUNCTION user_can(text, text, uuid) IS
  'Row-level permission check. '
  'Path A: is_super_admin() — UUID allowlist bypass (migration 112). '
  'Path B: p_owner=NULL — admin module, no target scoping. '
  'Path C: p_owner = caller — self check, skip group scoping. '
  'Path D: scope-aware — everyone/custom/direct_l1/direct_l2/dept/country. '
  'Reads permission_set_assignments → permission_set_items directly. '
  'SECURITY DEFINER STABLE — Postgres caches per unique args within one query.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm user_can() no longer references has_role('admin')
SELECT proname,
       prosrc NOT LIKE '%has_role%' AS path_a_uses_is_super_admin
FROM   pg_proc
WHERE  proname = 'user_can';

-- Confirm is_super_admin() is called instead
SELECT proname,
       prosrc LIKE '%is_super_admin%' AS has_super_admin_path
FROM   pg_proc
WHERE  proname = 'user_can';

-- =============================================================================
-- END OF MIGRATION 113
--
-- Run order: 109 → 110 → 112 → 113
-- After applying: refresh the app — your super admin account bypasses everything.
-- The admin role now flows through the permission matrix like any other role.
-- =============================================================================
