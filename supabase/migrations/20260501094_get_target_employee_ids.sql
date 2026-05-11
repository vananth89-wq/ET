-- =============================================================================
-- Migration 094: get_target_employee_ids() RPC
--
-- Returns the set of employee UUIDs (employees.id) that the current user is
-- permitted to see for a given module + action, based entirely on their active
-- role_permissions and target_group assignments.
--
-- NO admin bypass — every user, including admins, goes through the same
-- permission-based resolution.  The permission matrix is the single source of
-- truth for what data each user can see.
--
-- Return semantics
-- ────────────────
--   NULL array
--     The user holds a permission for this module/action with target_group_id
--     IS NULL (i.e. a legacy "unrestricted" grant, no population scoping).
--     Caller should show ALL records.  This path exists for backward-compat
--     with role_permissions rows inserted before the target-group system.
--
--   uuid[]  (non-empty)
--     Restricted to exactly these employee UUIDs — the union of all target
--     groups resolved for the user's active permissions on this module/action.
--
--   uuid[]  (empty — '{}')
--     The user has no matching permission for this module/action at all.
--     Caller should show nothing.  In practice the UI should gate before
--     reaching this state, but the hook handles it as a zero-access safe stop.
--
-- Usage
-- ─────
--   SELECT get_target_employee_ids('expense_reports', 'view');
--
-- Scope resolution per target_group.scope_type
-- ─────────────────────────────────────────────
--   everyone / custom  → pre-computed target_group_members cache
--   direct_l1          → employees.manager_id = caller's employee_id
--   direct_l2          → L1 + their direct reports (skip-level)
--   same_department    → employees in the same dept as the caller
--   same_country       → employees in the same work_country as the caller
-- =============================================================================

CREATE OR REPLACE FUNCTION get_target_employee_ids(
  p_module text DEFAULT 'expense_reports',
  p_action text DEFAULT 'view'
)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_employee_id  uuid;
  v_ids          uuid[];
  v_unrestricted boolean := false;
BEGIN
  -- ── Check for an unrestricted permission (target_group_id IS NULL) ─────────
  -- This covers legacy grants made before the target-group system.
  -- A role that intentionally provides global access should use the system
  -- 'everyone' target group going forward; this path is kept for back-compat.
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles       ur
    JOIN   role_permissions  rp ON rp.role_id      = ur.role_id
    JOIN   permissions       p  ON p.id             = rp.permission_id
    JOIN   modules           m  ON m.id             = p.module_id
    WHERE  ur.profile_id        = v_uid
      AND  ur.is_active         = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > now())
      AND  m.code               = p_module
      AND  p.action             = p_action
      AND  rp.target_group_id  IS NULL
  ) INTO v_unrestricted;

  IF v_unrestricted THEN
    RETURN NULL;   -- NULL = unrestricted / show all
  END IF;

  -- ── Resolve current user's employee record (needed for live scope checks) ──
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- ── Resolve each distinct target group to employee UUIDs ──────────────────
  WITH target_groups_for_user AS (
    -- All distinct target groups the user holds for this module + action
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
  ),
  resolved AS (
    -- everyone / custom — use pre-computed cache
    SELECT tgm.member_id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   target_group_members   tgm ON tgm.group_id = tgfu.group_id
    WHERE  tgfu.scope_type IN ('everyone', 'custom')

    UNION

    -- direct_l1 — employees whose immediate manager is the current user
    SELECT e.id AS emp_id
    FROM   target_groups_for_user tgfu
    JOIN   employees e ON e.manager_id = v_employee_id
                       AND e.deleted_at IS NULL
    WHERE  tgfu.scope_type = 'direct_l1'

    UNION

    -- direct_l2 — direct reports (L1) + their direct reports (L2 / skip-level)
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

    -- same_department — employees in the same department as the current user
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

    -- same_country — employees sharing work_country with the current user
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

  -- Coalesce to empty array when no rows resolve (no permission → no access)
  RETURN COALESCE(v_ids, '{}');
END;
$$;

COMMENT ON FUNCTION get_target_employee_ids(text, text) IS
  'Returns employee UUIDs accessible to the current user for the given module+action. '
  'No admin bypass — every user is resolved through the permission matrix. '
  'NULL = unrestricted legacy grant (target_group IS NULL). '
  'Empty array = no matching permission at all. '
  'Called by the frontend useTargetPopulation hook.';

GRANT EXECUTE ON FUNCTION get_target_employee_ids(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'get_target_employee_ids' AS check,
       proname, pronargs, prosecdef
FROM   pg_proc
WHERE  proname = 'get_target_employee_ids';

-- =============================================================================
-- END OF MIGRATION 094
-- =============================================================================
