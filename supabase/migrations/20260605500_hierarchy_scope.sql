-- =============================================================================
-- Migration 500: Add 'hierarchy' scope_type — full org-tree downward
--
-- FEATURE
-- ───────
-- A new system target group with scope_type='hierarchy'.
-- When selected, the permission applies to ALL employees at ANY level below
-- the holder in the org chart — resolving recursively through every manager
-- under them, not just L1 or L2.
--
-- EXAMPLE
--   VP of Engineering → permission with scope 'hierarchy'
--   Covers: all directors, all managers under those directors, all ICs.
--   Any new node added to the tree is covered automatically (live query).
--
-- WHY LIVE QUERY, NOT CACHE
-- ─────────────────────────
-- Like direct_l1 / direct_l2 / same_department / same_country, the result
-- is caller-dependent: two different managers have different subtrees.
-- Pre-computing per-user subtrees into target_group_members would require
-- full resyncs on every manager_id change. A recursive CTE at query time is
-- the correct pattern — same as the existing relational scopes.
--
-- CHANGES
-- ───────
-- 1. ALTER TABLE target_groups  — expand scope_type CHECK to include 'hierarchy'
-- 2. INSERT system target group  — code='hierarchy', scope_type='hierarchy'
-- 3. user_can()                  — Path D: new 'hierarchy' branch (recursive CTE)
-- 4. get_target_population()     — 'hierarchy' branch in resolved CTE
--
-- NOT CHANGED
-- ───────────
--   sync_target_group_members()  — hierarchy is live; no cache needed
--   All RLS policies             — call user_can(), automatically covered
--   All existing rows            — scope_type values unchanged
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Expand scope_type CHECK constraint
-- ─────────────────────────────────────────────────────────────────────────────
-- The original CHECK is inline (no explicit name), so Postgres auto-names it.
-- We drop it by searching pg_constraint and recreate with the new value set.
-- Using DO block to handle the name dynamically — safe and idempotent.

DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM   pg_constraint
  WHERE  conrelid = 'target_groups'::regclass
    AND  contype  = 'c'
    AND  pg_get_constraintdef(oid) LIKE '%scope_type%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE target_groups DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END;
$$;

ALTER TABLE target_groups
  ADD CONSTRAINT target_groups_scope_type_check
  CHECK (scope_type IN (
    'self',
    'everyone',
    'direct_l1',
    'direct_l2',
    'hierarchy',
    'same_department',
    'same_country',
    'custom'
  ));


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Seed system target group
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO target_groups (code, label, scope_type, is_system)
VALUES ('hierarchy', 'All Levels (Full Hierarchy)', 'hierarchy', true)
ON CONFLICT (code) DO UPDATE
  SET label      = EXCLUDED.label,
      scope_type = EXCLUDED.scope_type;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. user_can() — add 'hierarchy' branch to Path D
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION user_can(
  p_module text,
  p_action text,
  p_owner  uuid
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
      AND  (psa.include_self = true OR p_owner IS DISTINCT FROM v_employee_id)
      AND  (

        -- ── self ──────────────────────────────────────────────────────────
        (tg.scope_type = 'self' AND p_owner = v_employee_id)

        -- ── everyone / custom — pre-computed cache ────────────────────────
        OR (
          tg.scope_type IN ('everyone', 'custom')
          AND EXISTS (
            SELECT 1 FROM target_group_members tgm
            WHERE  tgm.group_id  = tg.id
              AND  tgm.member_id = p_owner
          )
        )

        -- ── direct_l1 ─────────────────────────────────────────────────────
        OR (
          tg.scope_type = 'direct_l1'
          AND EXISTS (
            SELECT 1 FROM employees e
            WHERE  e.id         = p_owner
              AND  e.manager_id = v_employee_id
              AND  e.deleted_at IS NULL
          )
        )

        -- ── direct_l2 ─────────────────────────────────────────────────────
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

        -- ── hierarchy — full recursive subtree downward ───────────────────
        -- Walks the entire org tree below v_employee_id and checks if
        -- p_owner appears anywhere in it.
        -- CYCLE guard: if bad data creates a manager_id loop, PostgreSQL
        -- sets is_cycle=true on the revisited row and stops that branch.
        OR (
          tg.scope_type = 'hierarchy'
          AND EXISTS (
            WITH RECURSIVE subordinates AS (
              -- Seed: immediate direct reports
              SELECT e.id
              FROM   employees e
              WHERE  e.manager_id = v_employee_id
                AND  e.deleted_at IS NULL

              UNION ALL

              -- Recurse: each level's direct reports
              SELECT e.id
              FROM   employees    e
              JOIN   subordinates s ON e.manager_id = s.id
              WHERE  e.deleted_at IS NULL
            )
            CYCLE id SET is_cycle USING path
            SELECT 1 FROM subordinates WHERE id = p_owner AND NOT is_cycle
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
  'Path D: scope_type-aware — self/everyone/custom/direct_l1/direct_l2/hierarchy/dept/country. '
  'hierarchy: recursive CTE walks full org tree downward from caller. '
  'include_self=false on psa excludes the holder from their own record. '
  'No implicit self-bypass (Path C removed in mig 114).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_target_population() — add 'hierarchy' branch
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

  -- Check if any matching assignment permits self (mig 499)
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    WHERE  ur.profile_id    = v_uid
      AND  ur.is_active     = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code           = p_module
      AND  p.action         = p_action
      AND  psa.include_self = true
  ) INTO v_any_include_self;

  -- everyone scope with include_self=true → mode=all
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles                ur
    JOIN   permission_set_assignments psa ON psa.role_id          = ur.role_id
    JOIN   permission_set_items       psi ON psi.permission_set_id = psa.permission_set_id
    JOIN   permissions                p   ON p.id                  = psi.permission_id
    JOIN   modules                    m   ON m.id                  = p.module_id
    JOIN   target_groups              tg  ON tg.id                 = psa.target_group_id
    WHERE  ur.profile_id    = v_uid
      AND  ur.is_active     = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code           = p_module
      AND  p.action         = p_action
      AND  tg.scope_type    = 'everyone'
      AND  psa.include_self = true
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

    -- self (ESS)
    SELECT v_employee_id AS emp_id
    FROM   target_groups_for_user WHERE scope_type = 'self'
      AND  v_employee_id IS NOT NULL

    UNION

    -- custom / everyone (include_self=false case)
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type IN ('custom', 'everyone')

    UNION

    -- direct_l1
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.manager_id = v_employee_id AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'direct_l1'

    UNION

    -- direct_l2
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.deleted_at IS NULL
      AND  (
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

    -- hierarchy — full recursive subtree (cycle-safe)
    SELECT s.id AS emp_id
    FROM   target_groups_for_user tgfu
    CROSS  JOIN LATERAL (
      WITH RECURSIVE subordinates AS (
        SELECT e.id
        FROM   employees e
        WHERE  e.manager_id = v_employee_id
          AND  e.deleted_at IS NULL

        UNION ALL

        SELECT e.id
        FROM   employees    e
        JOIN   subordinates s ON e.manager_id = s.id
        WHERE  e.deleted_at IS NULL
      )
      CYCLE id SET is_cycle USING path
      SELECT id FROM subordinates WHERE NOT is_cycle
    ) s
    WHERE  tgfu.scope_type = 'hierarchy'

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

  -- Apply include_self=false: strip caller from result when no assignment permits self
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
  'Scopes: self/everyone/custom/direct_l1/direct_l2/hierarchy/same_department/same_country. '
  'hierarchy: full recursive subtree downward via LATERAL recursive CTE. '
  'mode=all: everyone scope with include_self=true. '
  'mode=scoped: restricted ids. mode=none: no access.';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- New scope_type value accepted
SELECT id, code, label, scope_type, is_system
FROM   target_groups
WHERE  code = 'hierarchy';

-- CHECK constraint updated
SELECT pg_get_constraintdef(oid)
FROM   pg_constraint
WHERE  conrelid = 'target_groups'::regclass AND contype = 'c'
  AND  pg_get_constraintdef(oid) LIKE '%hierarchy%';

-- user_can has hierarchy branch
SELECT prosrc LIKE '%hierarchy%' AS has_hierarchy_branch
FROM   pg_proc WHERE proname = 'user_can';

-- =============================================================================
-- END OF MIGRATION 500
-- Run after: 499
-- =============================================================================
