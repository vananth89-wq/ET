-- =============================================================================
-- Migration 098: employees core table RLS
--
-- Replaces the flat has_permission() / has_role('admin') guards on the
-- employees table with user_can()-based policies.  Three lifecycle modules
-- share this single table — routing is by employees.status:
--
--   employee_details   → status = 'Active'
--   inactive_employees → status = 'Inactive'
--   hire_employee      → status IN ('Draft', 'Incomplete')
--
-- SELECT policy — status routing
-- ──────────────────────────────
--   Active rows:          user_can('employee_details',   'view', id)
--   Inactive rows:        user_can('inactive_employees', 'view', id)
--   Draft/Incomplete:     user_can('hire_employee',      'view', id)
--   Own record always:    id = get_my_employee_id()
--
-- INSERT policy — hire pipeline only
-- ───────────────────────────────────
--   user_can('hire_employee', 'create', NULL)
--   Path A (NULL) — no target group check, just permission existence.
--   Hire creates a new employee — there is no target employee_id yet.
--
-- UPDATE policy — three branches
-- ────────────────────────────────
--   Own record:          id = get_my_employee_id() (ESS self-service)
--   Active employee:     user_can('employee_details',   'edit', id)
--   Deactivate:          user_can('inactive_employees', 'create', id)  ← Active→Inactive
--   Reactivate:          user_can('inactive_employees', 'edit', id)    ← Inactive→Active
--   Hire pipeline edit:  user_can('hire_employee',      'edit', id)
--
-- DELETE policy — two branches
-- ─────────────────────────────
--   Active employee:    user_can('employee_details',   'delete', id)
--   Inactive employee:  user_can('inactive_employees', 'delete', id)
--   Draft/Incomplete:   user_can('hire_employee',      'delete', id)
--
-- NOTE: org_chart.view is NOT in this RLS.
--   org_chart is a frontend feature gate only.  Employees visible on the
--   org chart are entirely controlled by employee_details.view target group.
--   org_chart.view alone → screen opens but returns 0 rows (blank chart).
-- =============================================================================

-- Drop all existing employees policies
DROP POLICY IF EXISTS employees_select        ON employees;
DROP POLICY IF EXISTS employees_insert        ON employees;
DROP POLICY IF EXISTS employees_update        ON employees;
DROP POLICY IF EXISTS employees_delete        ON employees;
DROP POLICY IF EXISTS rbp_employees_select    ON employees;
DROP POLICY IF EXISTS rbp_employees_insert    ON employees;
DROP POLICY IF EXISTS rbp_employees_update    ON employees;
DROP POLICY IF EXISTS rbp_employees_delete    ON employees;


-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT — status-routed, three modules + own record
-- ─────────────────────────────────────────────────────────────────────────────

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      -- Own record always visible (ESS self-service path)
      id = get_my_employee_id()

      -- Active employees (employee_details.view — target group controls scope)
      -- target_group='self' covers ESS: user sees their own row via employee_details.view
      OR (status = 'Active'     AND user_can('employee_details',   'view', id))

      -- Inactive employees (separate module — admin controls who can see inactive)
      OR (status = 'Inactive'   AND user_can('inactive_employees', 'view', id))

      -- Hire pipeline — Draft / Incomplete employees
      OR (status IN ('Draft', 'Incomplete') AND user_can('hire_employee', 'view', id))

      -- NOTE: org_chart.view is NOT here — it is a frontend feature gate only.
      -- Org chart row visibility is controlled entirely by employee_details.view target group.
      -- org_chart.view alone → screen opens but returns blank (no employee_details.view = no rows).
    )
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- INSERT — hire pipeline only (Path A: NULL employee_id, permission check only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE POLICY employees_insert ON employees FOR INSERT
  WITH CHECK (
    user_can('hire_employee', 'create', NULL)
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- UPDATE — self-service OR module-specific permission
-- ─────────────────────────────────────────────────────────────────────────────

CREATE POLICY employees_update ON employees FOR UPDATE
  USING (
    -- ESS: own record (name, emergency contact, profile photo etc.)
    id = get_my_employee_id()

    -- Admin: edit active employee data
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))

    -- Deactivation: Active → Inactive (inactive_employees.create = deactivate action)
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))

    -- Reactivation: Inactive → Active (inactive_employees.edit = status change)
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))

    -- Hire pipeline: edit draft/incomplete records
    OR (status IN ('Draft', 'Incomplete') AND user_can('hire_employee', 'edit', id))
  )
  WITH CHECK (
    id = get_my_employee_id()
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))
    OR (status IN ('Draft', 'Incomplete') AND user_can('hire_employee', 'edit', id))
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- DELETE — module-specific permission per status
-- ─────────────────────────────────────────────────────────────────────────────

CREATE POLICY employees_delete ON employees FOR DELETE
  USING (
    (status = 'Active'                    AND user_can('employee_details',   'delete', id))
    OR (status = 'Inactive'               AND user_can('inactive_employees', 'delete', id))
    OR (status IN ('Draft', 'Incomplete') AND user_can('hire_employee',      'delete', id))
  );


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE tablename = 'employees'
ORDER BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 098
-- =============================================================================
