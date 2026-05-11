-- =============================================================================
-- Migration 084: RBP Phase 3 — user_can() + rbp_* RLS Policies
--
-- WHAT THIS DOES
-- ══════════════
-- 1. user_can(p_module text, p_action text, p_owner uuid)
--    SECURITY DEFINER STABLE — four execution paths:
--
--    A. has_role('admin')          → always true
--    B. p_owner IS NULL            → Admin-module path: role has permission
--                                    with target_group_id IS NULL
--    C. p_owner = my employee_id   → Self short-circuit: permission exists
--                                    through any role (no group check)
--    D. otherwise                  → EV path: scope_type-aware check
--                                    ├─ everyone/custom  → cache lookup
--                                    ├─ direct_l1        → LIVE manager_id check
--                                    ├─ direct_l2        → LIVE L1+L2 check
--                                    ├─ same_department  → LIVE dept_id check
--                                    └─ same_country     → LIVE work_country check
--
--    WHY scope_type-aware for direct_l1/L2?
--    A flat (group_id, member_id) cache cannot encode "E reports to M
--    specifically".  A single 'direct_l1' group containing all subordinates
--    would grant every manager access to every non-root employee — equivalent
--    to 'everyone'.  The live employees.manager_id lookup is fast (indexed,
--    small table) and gives the correct per-manager result.
--
-- 2. explain_user_can(p_uid, p_module, p_action, p_owner)
--    Debug RPC for the RBP Troubleshooter. Requires workflow.rbp_troubleshoot.
--
-- 3. rbp_* RLS policies on expense_reports, line_items, attachments.
--    Dual-coverage: old policies kept until Phase 5 UAT sign-off.
--
--    Dual-control gate (allow_edit):
--    ┌──────────────────────┬──────────────────────┬──────────┐
--    │ user_can(.., edit)   │ workflow_steps        │ Allowed? │
--    │                      │ .allow_edit + pending │          │
--    ├──────────────────────┼──────────────────────┼──────────┤
--    │ false                │ any                  │ NO       │
--    │ true                 │ false / no task      │ Owner    │
--    │                      │                      │ only     │
--    │ true                 │ true + assigned       │ Owner +  │
--    │                      │                      │ Approver │
--    └──────────────────────┴──────────────────────┴──────────┘
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. user_can()
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
  --   Caller passes p_owner = NULL for tables like departments, picklists.
  --   Checks role_permissions rows where target_group_id IS NULL.
  IF p_owner IS NULL THEN
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
    ) INTO v_result;
    RETURN COALESCE(v_result, false);
  END IF;

  -- ── Resolve caller's employee_id ─────────────────────────────────────────
  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = v_uid;

  -- ── Path C: Self short-circuit ────────────────────────────────────────────
  --   p_owner is the caller → skip group check entirely.
  --   Just verify the user holds the permission through any role.
  IF p_owner = v_employee_id THEN
    SELECT EXISTS (
      SELECT 1
      FROM   user_roles       ur
      JOIN   role_permissions  rp ON rp.role_id = ur.role_id
      JOIN   permissions       p  ON p.id        = rp.permission_id
      JOIN   modules           m  ON m.id        = p.module_id
      WHERE  ur.profile_id   = v_uid
        AND  ur.is_active    = true
        AND  (ur.expires_at IS NULL OR ur.expires_at > now())
        AND  m.code          = p_module
        AND  p.action        = p_action
    ) INTO v_result;
    RETURN COALESCE(v_result, false);
  END IF;

  -- ── Path D: EV path — scope_type-aware permission + membership check ──────
  --   Joins target_groups to read scope_type, then branches per type.
  --   'everyone' / 'custom': use the pre-computed target_group_members cache.
  --   All others: live employee-table checks (correct + fast on small tables).
  SELECT EXISTS (
    SELECT 1
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
      AND  (
        -- ── everyone / custom — cache lookup ─────────────────────────────
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
                -- Direct report (L1)
                e.manager_id = v_employee_id
                -- Skip-level report (L2): e.manager.manager = current user
                OR EXISTS (
                  SELECT 1 FROM employees l1
                  WHERE  l1.id         = e.manager_id
                    AND  l1.manager_id = v_employee_id
                    AND  l1.deleted_at IS NULL
                )
              )
          )
        )

        -- ── same_department — p_owner and current user share dept_id ─────
        OR (
          tg.scope_type = 'same_department'
          AND EXISTS (
            SELECT 1
            FROM   employees e_owner
            JOIN   employees e_me ON e_me.id = v_employee_id
            WHERE  e_owner.id       = p_owner
              AND  e_owner.dept_id  = e_me.dept_id
              AND  e_owner.dept_id  IS NOT NULL
              AND  e_owner.deleted_at IS NULL
          )
        )

        -- ── same_country — p_owner and current user share work_country ───
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
  'SECURITY DEFINER STABLE — Postgres caches per unique args within one query. '
  'Path D branches on scope_type: everyone→cache, direct_l1/L2/dept/country→live.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. explain_user_can() — debug RPC for RBP Troubleshooter
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION explain_user_can(
  p_uid    uuid,   -- profile_id of the user being inspected
  p_module text,
  p_action text,
  p_owner  uuid    -- employee_id of the record; NULL = admin module
)
RETURNS TABLE (
  result         boolean,
  path_taken     text,
  reason         text,
  matching_role  text,
  matching_group text
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
  v_is_admin    boolean;
  v_result      boolean := false;
  v_path        text;
  v_reason      text;
  v_role        text;
  v_group       text;
BEGIN
  IF NOT has_permission('workflow.rbp_troubleshoot') THEN
    RAISE EXCEPTION 'permission denied: workflow.rbp_troubleshoot required';
  END IF;

  -- Path A check
  SELECT EXISTS (
    SELECT 1 FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.profile_id = p_uid AND ur.is_active = true AND r.code = 'admin'
  ) INTO v_is_admin;

  IF v_is_admin THEN
    RETURN QUERY SELECT
      true, 'A: Admin bypass'::text,
      'User holds the admin role — all permissions granted unconditionally.'::text,
      'admin'::text, NULL::text;
    RETURN;
  END IF;

  -- Path B
  IF p_owner IS NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM user_roles ur
      JOIN role_permissions rp ON rp.role_id = ur.role_id
      JOIN permissions p ON p.id = rp.permission_id
      JOIN modules m ON m.id = p.module_id
      WHERE ur.profile_id = p_uid AND ur.is_active = true
        AND (ur.expires_at IS NULL OR ur.expires_at > now())
        AND m.code = p_module AND p.action = p_action
        AND rp.target_group_id IS NULL
    ) INTO v_result;

    SELECT r.code INTO v_role
    FROM user_roles ur JOIN roles r ON r.id = ur.role_id
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions perm ON perm.id = rp.permission_id
    JOIN modules m ON m.id = perm.module_id
    WHERE ur.profile_id = p_uid AND ur.is_active = true
      AND m.code = p_module AND perm.action = p_action
      AND rp.target_group_id IS NULL
    LIMIT 1;

    RETURN QUERY SELECT v_result, 'B: Admin-module path'::text,
      CASE WHEN v_result
        THEN 'Role ' || COALESCE(v_role,'?') || ' grants ' || p_module || '.' || p_action || ' (no target group).'
        ELSE 'No role grants ' || p_module || '.' || p_action || ' with NULL target_group.'
      END::text, v_role, NULL::text;
    RETURN;
  END IF;

  SELECT employee_id INTO v_employee_id FROM profiles WHERE id = p_uid;

  -- Path C
  IF p_owner = v_employee_id THEN
    SELECT EXISTS (
      SELECT 1 FROM user_roles ur
      JOIN role_permissions rp ON rp.role_id = ur.role_id
      JOIN permissions p ON p.id = rp.permission_id
      JOIN modules m ON m.id = p.module_id
      WHERE ur.profile_id = p_uid AND ur.is_active = true
        AND (ur.expires_at IS NULL OR ur.expires_at > now())
        AND m.code = p_module AND p.action = p_action
    ) INTO v_result;

    RETURN QUERY SELECT v_result, 'C: Self short-circuit'::text,
      CASE WHEN v_result
        THEN 'p_owner = caller employee_id; holds ' || p_module || '.' || p_action || ' through at least one role.'
        ELSE 'p_owner = caller but no role grants ' || p_module || '.' || p_action || '.'
      END::text, NULL::text, NULL::text;
    RETURN;
  END IF;

  -- Path D
  SELECT r.code, tg.code, EXISTS (
    SELECT 1 FROM user_roles ur2
    JOIN role_permissions rp2 ON rp2.role_id = ur2.role_id
    JOIN permissions p2 ON p2.id = rp2.permission_id
    JOIN modules m2 ON m2.id = p2.module_id
    JOIN target_groups tg2 ON tg2.id = rp2.target_group_id
    WHERE ur2.profile_id = p_uid AND ur2.is_active = true
      AND (ur2.expires_at IS NULL OR ur2.expires_at > now())
      AND m2.code = p_module AND p2.action = p_action
      AND (
        (tg2.scope_type IN ('everyone','custom') AND EXISTS (
          SELECT 1 FROM target_group_members tgm WHERE tgm.group_id = tg2.id AND tgm.member_id = p_owner
        ))
        OR (tg2.scope_type = 'direct_l1' AND EXISTS (
          SELECT 1 FROM employees e WHERE e.id = p_owner AND e.manager_id = v_employee_id AND e.deleted_at IS NULL
        ))
        OR (tg2.scope_type = 'direct_l2' AND EXISTS (
          SELECT 1 FROM employees e WHERE e.id = p_owner AND e.deleted_at IS NULL
            AND (e.manager_id = v_employee_id OR EXISTS (
              SELECT 1 FROM employees l1 WHERE l1.id = e.manager_id AND l1.manager_id = v_employee_id AND l1.deleted_at IS NULL
            ))
        ))
        OR (tg2.scope_type = 'same_department' AND EXISTS (
          SELECT 1 FROM employees eo JOIN employees em ON em.id = v_employee_id
          WHERE eo.id = p_owner AND eo.dept_id = em.dept_id AND eo.dept_id IS NOT NULL AND eo.deleted_at IS NULL
        ))
        OR (tg2.scope_type = 'same_country' AND EXISTS (
          SELECT 1 FROM employees eo JOIN employees em ON em.id = v_employee_id
          WHERE eo.id = p_owner AND eo.work_country = em.work_country AND eo.work_country IS NOT NULL AND eo.deleted_at IS NULL
        ))
      )
    LIMIT 1
  )
  INTO v_role, v_group, v_result
  FROM user_roles ur
  JOIN roles r ON r.id = ur.role_id
  LEFT JOIN role_permissions rp ON rp.role_id = ur.role_id
  LEFT JOIN target_groups tg ON tg.id = rp.target_group_id
  WHERE ur.profile_id = p_uid AND ur.is_active = true
  LIMIT 1;

  RETURN QUERY SELECT v_result, 'D: EV path (scope-aware)'::text,
    CASE WHEN v_result
      THEN 'Role ' || COALESCE(v_role,'?') || ' grants ' || p_module || '.' || p_action
           || ' via scope "' || COALESCE(v_group,'?') || '".'
      ELSE 'No role grants ' || p_module || '.' || p_action
           || ' covering this p_owner in any target group.'
    END::text, v_role, v_group;
END;
$$;

COMMENT ON FUNCTION explain_user_can(uuid, text, text, uuid) IS
  'Debug helper for RBP Troubleshooter. Reports path taken and reason. '
  'Requires workflow.rbp_troubleshoot permission.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: dual-gate check reused across policies
-- Returns true when the current auth.uid() is the active pending approver for
-- the given expense_report_id AND that step has allow_edit = true.
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE: Inlined in each policy for RLS compatibility (RLS cannot call helpers
-- directly), but extracted here as a comment block for clarity.
--
--   EXISTS (
--     SELECT 1
--     FROM   workflow_instances wi
--     JOIN   workflow_tasks     wt ON wt.instance_id = wi.id
--     JOIN   workflow_steps     ws ON ws.id           = wt.step_id
--     WHERE  wi.record_id   = <expense_report>.id
--       AND  wi.status      = 'in_progress'
--       AND  wt.assigned_to = auth.uid()
--       AND  wt.status      = 'pending'
--       AND  ws.allow_edit  = true
--   )
--
-- Tables and columns used:
--   workflow_instances : id, record_id, status
--   workflow_tasks     : instance_id, step_id, assigned_to, status
--   workflow_steps     : id, allow_edit


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. rbp_* RLS policies on expense_reports  (DUAL-COVERAGE — old kept)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── SELECT ───────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS rbp_expense_reports_select ON expense_reports;
CREATE POLICY rbp_expense_reports_select ON expense_reports
  FOR SELECT
  USING (
    user_can('expense_reports', 'view', employee_id)
  );

-- ── INSERT ───────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS rbp_expense_reports_insert ON expense_reports;
CREATE POLICY rbp_expense_reports_insert ON expense_reports
  FOR INSERT
  WITH CHECK (
    user_can('expense_reports', 'create', employee_id)
  );

-- ── UPDATE ───────────────────────────────────────────────────────────────────
-- Gate: user_can(.., edit) AND (owner path OR dual-control approver path).
-- Dual-control: workflow_tasks.assigned_to = auth.uid() AND pending
--               AND workflow_steps.allow_edit = true.
DROP POLICY IF EXISTS rbp_expense_reports_update ON expense_reports;
CREATE POLICY rbp_expense_reports_update ON expense_reports
  FOR UPDATE
  USING (
    user_can('expense_reports', 'edit', employee_id)
    AND (
      employee_id = get_my_employee_id()
      OR EXISTS (
        SELECT 1
        FROM   workflow_instances  wi
        JOIN   workflow_tasks      wt ON wt.instance_id = wi.id
        JOIN   workflow_steps      ws ON ws.id           = wt.step_id
        WHERE  wi.record_id    = expense_reports.id
          AND  wi.status       = 'in_progress'
          AND  wt.assigned_to  = auth.uid()
          AND  wt.status       = 'pending'
          AND  ws.allow_edit   = true
      )
    )
  );

-- ── DELETE ───────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS rbp_expense_reports_delete ON expense_reports;
CREATE POLICY rbp_expense_reports_delete ON expense_reports
  FOR DELETE
  USING (
    user_can('expense_reports', 'delete', employee_id)
    AND employee_id = get_my_employee_id()
    AND status = 'draft'
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. rbp_* RLS policies on line_items
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS rbp_line_items_select ON line_items;
CREATE POLICY rbp_line_items_select ON line_items
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE  er.id = line_items.report_id
        AND  user_can('expense_reports', 'view', er.employee_id)
    )
  );

DROP POLICY IF EXISTS rbp_line_items_insert ON line_items;
CREATE POLICY rbp_line_items_insert ON line_items
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE  er.id = line_items.report_id
        AND  user_can('expense_reports', 'edit', er.employee_id)
    )
  );

DROP POLICY IF EXISTS rbp_line_items_update ON line_items;
CREATE POLICY rbp_line_items_update ON line_items
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE  er.id = line_items.report_id
        AND  user_can('expense_reports', 'edit', er.employee_id)
        AND (
          er.employee_id = get_my_employee_id()
          OR EXISTS (
            SELECT 1
            FROM   workflow_instances  wi
            JOIN   workflow_tasks      wt ON wt.instance_id = wi.id
            JOIN   workflow_steps      ws ON ws.id           = wt.step_id
            WHERE  wi.record_id   = er.id
              AND  wi.status      = 'in_progress'
              AND  wt.assigned_to = auth.uid()
              AND  wt.status      = 'pending'
              AND  ws.allow_edit  = true
          )
        )
    )
  );

DROP POLICY IF EXISTS rbp_line_items_delete ON line_items;
CREATE POLICY rbp_line_items_delete ON line_items
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM expense_reports er
      WHERE  er.id = line_items.report_id
        AND  user_can('expense_reports', 'delete', er.employee_id)
        AND  er.employee_id = get_my_employee_id()
        AND  er.status = 'draft'
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. rbp_* RLS policies on attachments
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS rbp_attachments_select ON attachments;
CREATE POLICY rbp_attachments_select ON attachments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM   line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.deleted_at IS NULL
        AND  (
          user_can('expense_reports', 'view', er.employee_id)
          OR EXISTS (
            -- Pending approver can always see attachments even without broader view
            SELECT 1
            FROM   workflow_instances  wi
            JOIN   workflow_tasks      wt ON wt.instance_id = wi.id
            WHERE  wi.record_id   = er.id
              AND  wi.status      = 'in_progress'
              AND  wt.assigned_to = auth.uid()
              AND  wt.status      = 'pending'
          )
        )
    )
  );

DROP POLICY IF EXISTS rbp_attachments_insert ON attachments;
CREATE POLICY rbp_attachments_insert ON attachments
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM   line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.deleted_at IS NULL
        AND  (
          -- Owner adding to their own draft / rejected report
          (
            er.employee_id = get_my_employee_id()
            AND user_can('expense_reports', 'edit', er.employee_id)
          )
          -- Approver adding supporting docs (dual-control gate)
          OR EXISTS (
            SELECT 1
            FROM   workflow_instances  wi
            JOIN   workflow_tasks      wt ON wt.instance_id = wi.id
            JOIN   workflow_steps      ws ON ws.id           = wt.step_id
            WHERE  wi.record_id   = er.id
              AND  wi.status      = 'in_progress'
              AND  wt.assigned_to = auth.uid()
              AND  wt.status      = 'pending'
              AND  ws.allow_edit  = true
              AND  user_can('expense_reports', 'edit', er.employee_id)
          )
        )
    )
  );

DROP POLICY IF EXISTS rbp_attachments_delete ON attachments;
CREATE POLICY rbp_attachments_delete ON attachments
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1
      FROM   line_items li
      JOIN   expense_reports er ON er.id = li.report_id
      WHERE  li.id       = attachments.line_item_id
        AND  er.deleted_at IS NULL
        AND  er.employee_id = get_my_employee_id()
        AND  user_can('expense_reports', 'delete', er.employee_id)
        AND  er.status = 'draft'
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'user_can function' AS check,
  proname,
  prosecdef AS security_definer,
  CASE provolatile WHEN 's' THEN 'STABLE' WHEN 'i' THEN 'IMMUTABLE' ELSE 'VOLATILE' END AS volatility
FROM   pg_proc
WHERE  proname = 'user_can'
  AND  pronamespace = 'public'::regnamespace;

SELECT 'rbp policies on expense_reports' AS check,
  policyname, cmd
FROM   pg_policies
WHERE  schemaname = 'public' AND tablename = 'expense_reports'
  AND  policyname LIKE 'rbp_%'
ORDER  BY cmd;

SELECT 'rbp policies on attachments' AS check,
  policyname, cmd
FROM   pg_policies
WHERE  schemaname = 'public' AND tablename = 'attachments'
  AND  policyname LIKE 'rbp_%'
ORDER  BY cmd;

SELECT 'allow_edit on workflow_steps' AS check,
  column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_name = 'workflow_steps' AND column_name = 'allow_edit';
