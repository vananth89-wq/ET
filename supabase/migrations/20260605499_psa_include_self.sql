-- =============================================================================
-- Migration 499: Add include_self flag to permission_set_assignments
--
-- FEATURE
-- ───────
-- Adds a boolean column `include_self` to `permission_set_assignments`.
-- When true (default): the permission applies to ALL employees in the target
--   group, including the holder themselves — existing behaviour, unchanged.
-- When false: the permission applies to everyone in the target group EXCEPT
--   the holder themselves. Useful for HR roles where the admin should not be
--   able to access their own restricted data via the admin permission set.
--
-- BACKWARD COMPATIBILITY
-- ──────────────────────
-- DEFAULT true  → every existing row is unaffected, no behaviour change.
-- Only user_can() and get_target_population() are updated; all RLS policies
-- call these helpers, so no policy changes are required.
--
-- SCOPE OF CHANGE
-- ───────────────
-- 1. ALTER TABLE permission_set_assignments — ADD COLUMN include_self
-- 2. user_can()            — Path D gets one extra AND guard
-- 3. get_target_population() — excludes v_employee_id when include_self=false
--
-- NOT CHANGED
-- ───────────
--   target_groups / target_group_members — no change
--   scope_type='self' (ESS)              — unrelated, untouched
--   All RLS policies                     — no change
--   All other RPCs                       — no change
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Schema change
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE permission_set_assignments
  ADD COLUMN IF NOT EXISTS include_self boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN permission_set_assignments.include_self IS
  'When false the holder is excluded from their own target population — '
  'the permission applies to all scoped employees EXCEPT themselves. '
  'Default true preserves existing behaviour for all existing rows.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. user_can() — Path D: add include_self guard
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

  -- ── Path A: Super admin bypass ────────────────────────────────────────────
  IF is_super_admin() THEN RETURN true; END IF;

  -- ── Path B: Admin-module (no target scoping) ─────────────────────────────
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

  -- ── Resolve caller's employee_id ──────────────────────────────────────────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- ── Path D: scope_type-aware permission + target group check ─────────────
  --   New guard: (psa.include_self = true OR p_owner <> v_employee_id)
  --   When include_self=false and p_owner = caller → condition is false → denied.
  --   All other cases (different employee, or include_self=true) → unchanged.
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
      -- ── include_self guard (new) ─────────────────────────────────────────
      AND  (psa.include_self = true OR p_owner IS DISTINCT FROM v_employee_id)
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
  'include_self=false on psa excludes the holder from accessing their own record '
  'via this assignment. No implicit self-bypass (Path C removed in mig 114).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_target_population() — exclude self when include_self=false
-- ─────────────────────────────────────────────────────────────────────────────
--
-- If ALL matching assignments for this module+action have include_self=false,
-- the caller's own employee_id is removed from the result.
-- If at least one assignment has include_self=true, self remains (because that
-- other assignment would grant the access anyway).
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
  v_uid              uuid := auth.uid();
  v_employee_id      uuid;
  v_has_everyone     boolean := false;
  v_has_perm         boolean := false;
  v_any_include_self boolean := false;
  v_ids              uuid[];
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

  -- Check if any matching assignment has include_self=true
  -- (if so, self must remain in the result regardless of other assignments)
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
      AND  psa.include_self = true
  ) INTO v_any_include_self;

  -- everyone scope → mode=all (then handle include_self below)
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
      AND  psa.include_self = true   -- only full-everyone if self is included
  ) INTO v_has_everyone;

  IF v_has_everyone THEN
    RETURN jsonb_build_object('mode', 'all');
  END IF;

  -- Check if there's an everyone scope but with include_self=false
  -- → mode=all would be wrong; fall through to scoped with self excluded

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
      AND  tg.scope_type <> 'everyone'  -- everyone already handled above
  ),
  resolved AS (

    -- self scope (ESS) — not affected by include_self; always the caller's own id
    SELECT v_employee_id AS emp_id
    FROM   target_groups_for_user tgfu
    WHERE  tgfu.scope_type = 'self'
      AND  v_employee_id IS NOT NULL

    UNION

    -- custom / everyone (include_self=false case) — pre-computed cache
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type IN ('custom', 'everyone')

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

  -- Apply include_self=false: remove caller from ids if no assignment permits self
  IF NOT v_any_include_self AND v_employee_id IS NOT NULL AND v_ids IS NOT NULL THEN
    v_ids := array_remove(v_ids, v_employee_id);
  END IF;

  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RETURN jsonb_build_object('mode', 'none', 'reason', 'empty_group');
  END IF;

  RETURN jsonb_build_object('mode', 'scoped', 'ids', to_jsonb(v_ids));
END;
$$;

COMMENT ON FUNCTION get_target_population(text, text) IS
  'Returns the target population for the current user on a given module+action. '
  'Scopes: self / everyone / custom / direct_l1 / direct_l2 / same_department / same_country. '
  'mode=all: everyone scope with include_self=true. '
  'mode=scoped: restricted ids (self excluded when all assignments have include_self=false). '
  'mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- Column exists with correct default
SELECT column_name, data_type, column_default, is_nullable
FROM   information_schema.columns
WHERE  table_name  = 'permission_set_assignments'
  AND  column_name = 'include_self';

-- All existing rows have include_self = true (backward compat check)
SELECT COUNT(*) AS rows_with_false
FROM   permission_set_assignments
WHERE  include_self = false;

-- user_can has the new guard
SELECT prosrc LIKE '%include_self%' AS has_include_self_guard
FROM   pg_proc WHERE proname = 'user_can';

-- =============================================================================
-- END OF MIGRATION 499
-- =============================================================================
