-- =============================================================================
-- Migration 221: Fix employees DELETE policy — hire pipeline Path B + Pending
--
-- ROOT CAUSE
-- ──────────
-- The employees_delete policy was established in migration 098 and never
-- updated. It has two problems:
--
--   1. 'Pending' status is missing — introduced in migration 217 but not
--      reflected in the DELETE policy, so Pending employees cannot be deleted.
--
--   2. Still uses Path D for hire pipeline:
--        user_can('hire_employee', 'delete', id)
--      This requires the employee to be in the target_group_members cache.
--      Newly created Draft employees are never in that cache, so deletion
--      returns 403 Forbidden even for users with the correct permission.
--
-- FIX
-- ───
-- Rebuild employees_delete using the same Path B pattern as migration 219
-- (employees_select / employees_update):
--   • 'Pending' added to the hire-pipeline status set
--   • Path B (NULL owner) used for hire pipeline — no cache required
--
-- WHY Path B IS CORRECT FOR DELETE
-- ──────────────────────────────────
-- Deleting a Draft/Incomplete/Pending hire is an admin-level action, identical
-- in nature to creating one (which already uses Path B). There is no meaningful
-- "target group" to scope deletion by — the HR Analyst either has permission
-- to delete hires or they don't. Path B (permission existence) is the right gate.
-- =============================================================================


DROP POLICY IF EXISTS employees_delete ON employees;

CREATE POLICY employees_delete ON employees FOR DELETE
  USING (
    -- Active employee: scoped to target group (Path D)
    (status = 'Active'
        AND user_can('employee_details',   'delete', id))

    -- Inactive employee: scoped to target group (Path D)
    OR (status = 'Inactive'
        AND user_can('inactive_employees', 'delete', id))

    -- Hire pipeline: Draft / Incomplete / Pending
    -- Path B (NULL) — no target-group cache required.
    -- Permission existence is the only gate, same as INSERT.
    OR (status IN ('Draft', 'Incomplete', 'Pending')
        AND user_can('hire_employee', 'delete', NULL))
  );

COMMENT ON POLICY employees_delete ON employees IS
  'Status-routed DELETE. Active/Inactive use Path D (target-group scoped). '
  'Hire pipeline (Draft/Incomplete/Pending) uses Path B (NULL owner) — '
  'no target-group cache required. Pending added in mig 217.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT policyname, cmd, qual
FROM   pg_policies
WHERE  tablename = 'employees'
ORDER BY cmd, policyname;

-- =============================================================================
-- END OF MIGRATION 221
--
-- Run order: 219 → 220 → 221
-- After applying: employees_delete correctly handles all four status groups
-- including Pending, using Path B for the hire pipeline.
-- =============================================================================
