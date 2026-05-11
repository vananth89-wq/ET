-- =============================================================================
-- Migration 114: Add self scope to Path D, remove Path C from user_can()
--
-- ROOT CAUSE
-- ──────────
-- Migration 082 seeded a system target group with scope_type='self' and the
-- ESS permission_set_assignment already points to it (confirmed). However
-- user_can() Path D never had a branch for scope_type='self' — so Path C
-- (a self short-circuit that bypasses target group scoping entirely) was
-- added as a workaround. Path C was incorrect because it ignored which
-- target group the assignment was intended for.
--
-- THE FIX — two changes only:
--   1. Add scope_type='self' branch to Path D:
--        p_owner = v_employee_id  (record owner must be the caller)
--   2. Remove Path C entirely.
--
-- RESULT
-- ──────
-- user_can() now has three paths:
--   Path A: is_super_admin()        → immediate bypass (migration 113)
--   Path B: p_owner IS NULL         → admin module, no target scoping
--   Path D: permission + target     → scope_type-aware check including self
--
-- All access — including ESS self-service — is now fully matrix-driven.
-- No implicit bypasses remain except super admin.
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
--   All RLS policies               — unchanged
--   permission_set_assignments     — unchanged (ESS→self, admin→everyone already correct)
--   target_groups table            — unchanged (self scope_type already exists)
--   get_my_permissions()           — unchanged
--   get_target_population()        — updated below to handle self scope
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
  IF is_super_admin() THEN RETURN true; END IF;

  -- ── Path B: Admin-module (no target scoping) ─────────────────────────────
  --   p_owner = NULL for tables like departments, picklists, permission sets.
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

  -- ── Resolve caller's employee_id (needed for self + EV scope checks) ──────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- ── Path D: scope_type-aware permission + target group check ─────────────
  --   Handles ALL non-NULL owner cases including self-service.
  --   scope_type='self'  → p_owner must equal the caller's own employee_id.
  --   All other scopes   → unchanged from migration 107/113.
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

        -- ── self — caller is the record owner ────────────────────────────
        (
          tg.scope_type = 'self'
          AND p_owner = v_employee_id
        )

        -- ── everyone / custom — pre-computed cache ────────────────────────
        OR (
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
            WHERE  e_owner.id          = p_owner
              AND  e_owner.work_country = e_me.work_country
              AND  e_owner.work_country IS NOT NULL
              AND  e_owner.deleted_at  IS NULL
          )
        )

      )
  ) INTO v_result;

  RETURN COALESCE(v_result, false);
END;
$$;

COMMENT ON FUNCTION user_can(text, text, uuid) IS
  'Row-level permission check — three paths only. '
  'Path A: is_super_admin() — UUID allowlist bypass. '
  'Path B: p_owner=NULL — admin module, no target scoping. '
  'Path D: scope_type-aware — self/everyone/custom/direct_l1/direct_l2/dept/country. '
  'No implicit self-bypass (Path C removed). All access is matrix-driven.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Update get_target_population() — add self scope
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

  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- everyone scope → mode=all
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

    -- self — caller's own employee record only
    SELECT v_employee_id AS emp_id
    FROM   target_groups_for_user tgfu
    WHERE  tgfu.scope_type = 'self'
      AND  v_employee_id IS NOT NULL

    UNION

    -- custom — pre-computed cache
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type = 'custom'

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
    JOIN   employees e ON e.dept_id   = me.dept_id
                       AND e.dept_id  IS NOT NULL
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
  'Scopes: self / everyone / custom / direct_l1 / direct_l2 / same_department / same_country. '
  'mode=all: everyone scope. mode=scoped: restricted ids. mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm Path C (has_role / self short-circuit) is gone
SELECT proname,
       prosrc NOT LIKE '%v_employee_id THEN%' AS path_c_removed,
       prosrc LIKE '%is_super_admin%'          AS path_a_present,
       prosrc LIKE '%scope_type = ''self''%'   AS self_scope_present
FROM   pg_proc
WHERE  proname = 'user_can';

-- =============================================================================
-- END OF MIGRATION 114
--
-- Run order: 112 → 113 → 114
-- After applying: ESS self-access works via self scope in target_groups.
-- No implicit bypasses remain. All access is fully matrix-driven.
-- =============================================================================
