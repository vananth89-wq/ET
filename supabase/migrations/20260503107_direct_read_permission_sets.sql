-- =============================================================================
-- Migration 107: Direct read from permission_sets — no sync needed
--
-- APPROACH
-- ────────
-- Instead of syncing permission_sets → role_permissions via triggers (migration
-- 106, now superseded), we rewrite user_can() and get_target_population() to
-- read permission_set_assignments + permission_set_items directly.
--
-- role_permissions is NOT dropped — legacy rows stay untouched. But it is no
-- longer used by any enforcement function.
--
-- WHAT CHANGES
-- ────────────
--   user_can()             — join chain: role_permissions → permission_set chain
--   get_target_population()— target_group_id: rp.target_group_id → psa.target_group_id
--   get_my_permissions()   — simplified to Path B only (no more UNION with role_permissions)
--
-- WHAT DOES NOT CHANGE
-- ────────────────────
--   All 40+ RLS policies   — still call user_can(). No touch.
--   permission_set tables  — schema unchanged.
--   role_permissions table — kept, just no longer read for enforcement.
--   has_role()             — unchanged.
--
-- INDEXES added for the new join pattern:
--   permission_set_assignments(role_id)
--   permission_set_assignments(role_id, permission_set_id, target_group_id)
--   permission_set_items(permission_set_id)
--   permission_set_items(permission_set_id, permission_id)
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Performance indexes for the new join path
-- ─────────────────────────────────────────────────────────────────────────────

-- Join from user_roles → permission_set_assignments
CREATE INDEX IF NOT EXISTS idx_psa_role_id
  ON permission_set_assignments (role_id);

-- Covering index for role → set → target_group in one scan
CREATE INDEX IF NOT EXISTS idx_psa_role_set_tg
  ON permission_set_assignments (role_id, permission_set_id, target_group_id);

-- Join from permission_set_assignments → permission_set_items
CREATE INDEX IF NOT EXISTS idx_psi_set_id
  ON permission_set_items (permission_set_id);

-- Covering index for set → permission lookup
CREATE INDEX IF NOT EXISTS idx_psi_set_permission
  ON permission_set_items (permission_set_id, permission_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Rewrite user_can()
--
-- Four internal paths are preserved exactly.  Only the join chain changes:
--   OLD: user_roles → role_permissions → permissions → modules
--   NEW: user_roles → permission_set_assignments → permission_set_items
--                   → permissions → modules
--
-- target_group_id source:
--   OLD: role_permissions.target_group_id
--   NEW: permission_set_assignments.target_group_id
-- ─────────────────────────────────────────────────────────────────────────────

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

  -- ── Path A: Admin bypass ──────────────────────────────────────────────────
  IF has_role('admin') THEN RETURN true; END IF;

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
  --   target_group_id now comes from permission_set_assignments (not role_permissions).
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
  'Row-level permission check. p_owner=NULL for admin modules (no scoping). '
  'Reads permission_set_assignments → permission_set_items directly. '
  'No sync to role_permissions required. '
  'SECURITY DEFINER STABLE — Postgres caches per unique args within one query.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Rewrite get_target_population()
--
-- Same logic as before. Only the join chain changes:
--   OLD: user_roles → role_permissions → permissions → modules → target_groups
--   NEW: user_roles → permission_set_assignments → permission_set_items
--                   → permissions → modules
--        target_group_id from: permission_set_assignments.target_group_id
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

  -- ── Does the user have ANY permission for this module+action? ──────────────
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

  -- ── Does any assignment point to the 'everyone' target group? ─────────────
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
  'Reads permission_set_assignments directly — no role_permissions dependency. '
  'mode=all: everyone scope. mode=scoped: restricted ids. mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Simplify get_my_permissions() — Path B only
--
-- Migration 105 restored a UNION (Path A = role_permissions, Path B = sets).
-- Now that user_can() reads sets directly, role_permissions is no longer the
-- source of truth. Drop Path A — read permission_set_assignments only.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT p.code), '{}')
  FROM   user_roles                ur
  JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
  JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
  JOIN   permissions                p   ON p.id                  = psi.permission_id
  WHERE  ur.profile_id = auth.uid()
    AND  ur.is_active  = true
    AND  (ur.expires_at IS NULL OR ur.expires_at > now())
$$;

COMMENT ON FUNCTION get_my_permissions() IS
  'Returns all distinct permission codes for the current user. '
  'Single path: permission_set_assignments → permission_set_items → permissions. '
  'role_permissions is no longer read — permission_sets is the sole source of truth.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Indexes created
SELECT indexname, tablename
FROM   pg_indexes
WHERE  indexname IN (
  'idx_psa_role_id', 'idx_psa_role_set_tg',
  'idx_psi_set_id',  'idx_psi_set_permission'
)
ORDER BY indexname;

-- 2. Functions updated — confirm they no longer reference role_permissions
SELECT proname,
       prosrc NOT LIKE '%role_permissions%' AS reads_sets_not_rp
FROM   pg_proc
WHERE  proname IN ('user_can', 'get_target_population', 'get_my_permissions')
ORDER  BY proname;

-- Expected: reads_sets_not_rp = true for all three

-- =============================================================================
-- END OF MIGRATION 107
-- =============================================================================
