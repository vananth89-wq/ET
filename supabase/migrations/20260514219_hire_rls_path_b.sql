-- =============================================================================
-- Migration 219: Fix hire-pipeline RLS — use Path B (NULL owner) for
--                Draft / Incomplete / Pending employees
--
-- ROOT CAUSE
-- ──────────
-- employees_select and employees_update pass the employee's UUID as p_owner to
-- user_can(). This triggers Path D, which requires the record to already exist
-- in the target_group_members cache.
--
-- Newly created Draft employees are never pre-loaded into that cache, so:
--   1. INSERT succeeds   — user_can('hire_employee', 'create', NULL) → Path B ✓
--   2. SELECT fails      — user_can('hire_employee', 'view',   id)   → Path D,
--                          record not in cache → false
--   3. UPDATE fails      — user_can('hire_employee', 'edit',   id)   → Path D,
--                          record not in cache → false
--
-- WHY PATH B IS CORRECT HERE
-- ───────────────────────────
-- The hire pipeline (Draft / Incomplete / Pending) is an admin-level workflow,
-- not a target-group-scoped view. HR Analysts with hire_employee.view should
-- see ALL pending hires, just as hire_employee.create already uses Path B.
-- Scoping the live hire pipeline to target groups adds no security value and
-- breaks the workflow for new records that have no group membership yet.
--
-- FIX
-- ───
-- Replace user_can('hire_employee', 'view'/'edit', id) with
--          user_can('hire_employee', 'view'/'edit', NULL) for the hire-pipeline
-- status branch in both SELECT and UPDATE policies.
--
-- Also adds 'Pending' to the hire-pipeline status set (introduced in mig 217).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT — rebuild with Path B for hire pipeline
-- ─────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS employees_select ON employees;

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      -- Active employees (employee_details.view — target group controls scope)
      (status = 'Active'     AND user_can('employee_details',   'view', id))

      -- Inactive employees
      OR (status = 'Inactive'  AND user_can('inactive_employees', 'view', id))

      -- Hire pipeline: Draft / Incomplete / Pending
      -- Uses NULL (Path B) — no target-group cache required; permission
      -- existence is the only gate. Newly created hires are always visible.
      OR (status IN ('Draft', 'Incomplete', 'Pending')
          AND user_can('hire_employee', 'view', NULL))
    )
  );

COMMENT ON POLICY employees_select ON employees IS
  'Status-routed SELECT. Hire pipeline uses Path B (NULL owner) so newly created '
  'Draft/Incomplete/Pending records are immediately visible to HR Analysts.';


-- ─────────────────────────────────────────────────────────────────────────────
-- UPDATE — rebuild with Path B for hire pipeline
-- ─────────────────────────────────────────────────────────────────────────────
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
    user_can('personal_info', 'edit', id)
    OR (status = 'Active'   AND user_can('employee_details',   'edit',   id))
    OR (status = 'Active'   AND user_can('inactive_employees', 'create', id))
    OR (status = 'Inactive' AND user_can('inactive_employees', 'edit',   id))
    OR (status IN ('Draft', 'Incomplete', 'Pending')
        AND user_can('hire_employee', 'edit', NULL))
  );

COMMENT ON POLICY employees_update ON employees IS
  'Status-routed UPDATE. Hire pipeline uses Path B (NULL owner) — no target-group '
  'cache required. Covers Draft/Incomplete/Pending (Pending added in mig 217).';
