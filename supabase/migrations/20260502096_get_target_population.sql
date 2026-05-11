-- =============================================================================
-- Migration 096: get_target_population() RPC
--
-- Replaces the ambiguous NULL return of get_target_employee_ids() with an
-- explicit JSONB mode field.  Deployed ALONGSIDE the old function — non-breaking.
-- The old function remains live until migration 097 (hook update) is verified
-- in production, at which point it can be deprecated and eventually dropped.
--
-- Return semantics
-- ────────────────
--   { "mode": "all" }
--     The user holds a permission with the system 'everyone' target group.
--     Caller should show all active employees with no id filter.
--
--   { "mode": "scoped", "ids": ["uuid", ...] }
--     The user has a restricted grant.  Caller should filter to these UUIDs.
--     The array is always non-empty — an empty resolution collapses to "none".
--
--   { "mode": "none", "reason": "no_permission" | "empty_group" }
--     no_permission  — user holds no matching permission for this module+action.
--     empty_group    — permission row exists but the resolved target group has
--                      zero members (e.g. custom group with no members added yet).
--     In both cases: show nothing.
--
-- Why explicit mode instead of NULL?
-- ───────────────────────────────────
--   NULL is syntactically ambiguous in SQL and TypeScript — a null return from
--   a network call can mean "unrestricted" or "error" depending on the caller.
--   An explicit { mode: "all" } is unambiguous and safe to extend.
--
-- Usage
-- ─────
--   SELECT get_target_population('employee_details', 'view');
--   SELECT get_target_population('inactive_employees', 'view');
--
-- Frontend hook: useTargetPopulation (updated in migration 097 frontend task)
-- =============================================================================

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
    FROM   user_roles       ur
    JOIN   role_permissions  rp ON rp.role_id     = ur.role_id
    JOIN   permissions       p  ON p.id            = rp.permission_id
    JOIN   modules           m  ON m.id            = p.module_id
    WHERE  ur.profile_id       = v_uid
      AND  ur.is_active        = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code              = p_module
      AND  p.action            = p_action
  ) INTO v_has_perm;

  IF NOT v_has_perm THEN
    RETURN jsonb_build_object('mode', 'none', 'reason', 'no_permission');
  END IF;

  -- ── Does any of those permissions point to the 'everyone' target group? ───
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles       ur
    JOIN   role_permissions  rp ON rp.role_id     = ur.role_id
    JOIN   permissions       p  ON p.id            = rp.permission_id
    JOIN   modules           m  ON m.id            = p.module_id
    JOIN   target_groups     tg ON tg.id           = rp.target_group_id
    WHERE  ur.profile_id       = v_uid
      AND  ur.is_active        = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code              = p_module
      AND  p.action            = p_action
      AND  tg.scope_type       = 'everyone'
  ) INTO v_has_everyone;

  IF v_has_everyone THEN
    RETURN jsonb_build_object('mode', 'all');
  END IF;

  -- ── Resolve scoped target groups to employee UUIDs ────────────────────────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  WITH target_groups_for_user AS (
    SELECT DISTINCT tg.id AS group_id, tg.scope_type
    FROM   user_roles       ur
    JOIN   role_permissions  rp  ON rp.role_id = ur.role_id
    JOIN   permissions       p   ON p.id        = rp.permission_id
    JOIN   modules           m   ON m.id        = p.module_id
    JOIN   target_groups     tg  ON tg.id       = rp.target_group_id
    WHERE  ur.profile_id = v_uid
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code        = p_module
      AND  p.action      = p_action
      AND  tg.scope_type <> 'everyone'  -- already handled above
  ),
  resolved AS (
    -- custom — pre-computed cache
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type = 'custom'

    UNION

    -- self — the current user's own employee record only
    SELECT v_employee_id AS emp_id
    FROM   target_groups_for_user tgfu
    WHERE  tgfu.scope_type = 'self'
      AND  v_employee_id IS NOT NULL

    UNION

    -- direct_l1 — immediate direct reports
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.manager_id = v_employee_id
                       AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'direct_l1'

    UNION

    -- direct_l2 — direct reports + their direct reports (skip-level)
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
    CROSS  JOIN (
      SELECT dept_id FROM employees WHERE id = v_employee_id
    ) me
    JOIN   employees e ON e.dept_id    = me.dept_id
                       AND e.dept_id  IS NOT NULL
                       AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'same_department'

    UNION

    -- same_country
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    CROSS  JOIN (
      SELECT work_country FROM employees WHERE id = v_employee_id
    ) me
    JOIN   employees e ON e.work_country  = me.work_country
                       AND e.work_country IS NOT NULL
                       AND e.deleted_at   IS NULL
    WHERE  tgfu.scope_type = 'same_country'
  )
  SELECT array_agg(DISTINCT emp_id) INTO v_ids FROM resolved;

  -- ── Empty resolution → custom group has no members ────────────────────────
  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RETURN jsonb_build_object('mode', 'none', 'reason', 'empty_group');
  END IF;

  RETURN jsonb_build_object('mode', 'scoped', 'ids', to_jsonb(v_ids));
END;
$$;

COMMENT ON FUNCTION get_target_population(text, text) IS
  'Returns a JSONB object describing the target population for the current user '
  'on a given module+action. '
  'mode=all: everyone target group — no id filter. '
  'mode=scoped: restricted to ids array. '
  'mode=none: no access (reason=no_permission or empty_group). '
  'Deployed alongside get_target_employee_ids() — non-breaking. '
  'Switch frontend hook to this function (migration 097 task).';

GRANT EXECUTE ON FUNCTION get_target_population(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'get_target_population' AS check,
       proname,
       pronargs,
       prosecdef,
       prorettype::regtype AS return_type
FROM   pg_proc
WHERE  proname = 'get_target_population';

-- =============================================================================
-- END OF MIGRATION 096
-- =============================================================================
