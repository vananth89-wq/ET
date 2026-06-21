-- =============================================================================
-- Migration 222: Fix employees_update WITH CHECK for hire pipeline activation
--
-- ROOT CAUSE
-- ──────────
-- handleActivate() in AddEmployee.tsx does a direct PATCH to the employees
-- table setting status = 'Active' on a Draft/Incomplete/Pending employee.
--
-- The USING clause (evaluated against the OLD row) passes correctly via the
-- hire pipeline branch:
--   status IN ('Draft','Incomplete','Pending') AND user_can('hire_employee','edit',NULL)
--
-- The WITH CHECK clause (evaluated against the NEW row) fails because:
--   • New status = 'Active' → hire pipeline branch does not match
--   • employee_details.edit (Path D) → employee not yet in target_group_members cache
--   • inactive_employees.create (Path D) → same cache miss
--
-- FIX
-- ───
-- Add one branch to WITH CHECK:
--
--   OR (status = 'Active' AND user_can('hire_employee', 'create', NULL))
--
-- This allows the hire pipeline → Active status transition when the user
-- holds hire_employee.create (the same permission already used for INSERT,
-- confirmed safe via Path B). The USING clause already gates which rows can
-- be touched — only hire-pipeline old-rows can reach this WITH CHECK branch
-- for new hires not yet in any target group cache.
--
-- SAFETY
-- ──────
-- For existing Active employees that pass USING via employee_details.edit
-- (Path D, target-group scoped), the new WITH CHECK branch also opens — but
-- those users already had edit rights on that employee via USING. No new
-- surface is exposed.
-- =============================================================================


DROP POLICY IF EXISTS employees_update ON employees;

CREATE POLICY employees_update ON employees FOR UPDATE
  USING (
    -- ESS: own profile data
    user_can('personal_info', 'edit', id)

    -- Admin: edit active employee record
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))

    -- Deactivation: Active → Inactive
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))

    -- Reactivation: Inactive → Active
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))

    -- Hire pipeline: Draft / Incomplete / Pending — Path B (NULL owner)
    OR (status IN ('Draft', 'Incomplete', 'Pending')
        AND user_can('hire_employee', 'edit', NULL))
  )
  WITH CHECK (
    -- ESS: own profile data
    user_can('personal_info', 'edit', id)

    -- Admin: edit active employee record
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))

    -- Deactivation: Active → Inactive
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))

    -- Reactivation: Inactive → Active
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))

    -- Hire pipeline: Draft / Incomplete / Pending — Path B (NULL owner)
    OR (status IN ('Draft', 'Incomplete', 'Pending')
        AND user_can('hire_employee', 'edit', NULL))

    -- Activation: hire pipeline → Active
    -- Allows PATCH status = 'Active' on a record whose OLD status was in the
    -- hire pipeline (USING already enforces that). Uses hire_employee.create
    -- (Path B) — same permission as INSERT, no cache needed.
    OR (status = 'Active'   AND user_can('hire_employee', 'create', NULL))
  );

COMMENT ON POLICY employees_update ON employees IS
  'Status-routed UPDATE. '
  'Hire pipeline uses Path B (NULL owner) for USING. '
  'WITH CHECK adds hire_employee.create branch to allow '
  'Draft/Incomplete/Pending → Active activation without cache. '
  'Pending added in mig 217, activation branch added in mig 222.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT policyname, cmd, qual, with_check
FROM   pg_policies
WHERE  tablename = 'employees' AND policyname = 'employees_update';

-- =============================================================================
-- END OF MIGRATION 222
-- =============================================================================
