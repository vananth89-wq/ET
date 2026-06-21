-- Migration 256: Tighten employees_update RLS — add ownership check for hire pipeline
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM (Gap 11)
-- The hire pipeline branch in employees_update allows any user with
-- hire_employee.edit to UPDATE any Draft/Incomplete/Pending record regardless
-- of who created it. HR Analyst B could overwrite Analyst A's Draft directly.
--
-- SOLUTION
-- Split the hire pipeline branch into three distinct cases:
--
--   Draft / Incomplete
--     — creator (created_by = auth.uid())
--     — legacy records (created_by IS NULL — pre-mig 253)
--     — HR Head with hire_employee.edit_all_pending
--     — super admin
--
--   Pending (locked — submitted for approval)
--     — update_hire_field RPC is SECURITY DEFINER and handles approver edits
--       without touching RLS. Direct table UPDATE on a Pending record is only
--       allowed for HR Head (edit_all_pending) or super admin.
--     — Analysts are blocked from direct UPDATE of Pending records (the autosave
--       guard in the frontend already prevents it; this enforces it at DB level).
--
-- The WITH CHECK clause mirrors USING so the resulting row is equally guarded.
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

    -- Hire pipeline: Draft / Incomplete — creator, HR Head, or super admin only
    OR (status IN ('Draft', 'Incomplete')
        AND user_can('hire_employee', 'edit', NULL)
        AND (
          created_by IS NULL                                          -- legacy (pre-mig 253)
          OR created_by = auth.uid()                                  -- own record
          OR user_can('hire_employee', 'edit_all_pending', NULL)      -- HR Head
          OR is_super_admin()
        ))

    -- Hire pipeline: Pending — HR Head / super admin only
    -- (approver edits go through update_hire_field SECURITY DEFINER RPC)
    OR (status = 'Pending'
        AND (user_can('hire_employee', 'edit_all_pending', NULL) OR is_super_admin()))
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

    -- Hire pipeline: Draft / Incomplete — creator, HR Head, or super admin only
    OR (status IN ('Draft', 'Incomplete')
        AND user_can('hire_employee', 'edit', NULL)
        AND (
          created_by IS NULL
          OR created_by = auth.uid()
          OR user_can('hire_employee', 'edit_all_pending', NULL)
          OR is_super_admin()
        ))

    -- Hire pipeline: Pending — HR Head / super admin only
    OR (status = 'Pending'
        AND (user_can('hire_employee', 'edit_all_pending', NULL) OR is_super_admin()))

    -- Activation: hire pipeline → Active (hire_employee.create — same as INSERT)
    OR (status = 'Active' AND user_can('hire_employee', 'create', NULL))
  );

COMMENT ON POLICY employees_update ON employees IS
  'Status-routed UPDATE. '
  'Draft/Incomplete: only creator, HR Head (edit_all_pending), or super admin. '
  'Pending: only HR Head or super admin (approver edits use update_hire_field RPC). '
  'Active: employee_details.edit, deactivation/reactivation via inactive_employees. '
  'Activation: hire_employee.create. Mig 256: added ownership check to hire pipeline.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  tablename  = 'employees'
      AND  policyname = 'employees_update'
      AND  cmd        = 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'ABORT: employees_update policy not found after migration.';
  END IF;
  RAISE NOTICE 'Migration 256 verified: employees_update policy present.';
END;
$$;
