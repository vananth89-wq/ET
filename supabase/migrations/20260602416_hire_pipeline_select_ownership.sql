-- =============================================================================
-- Migration 416: Add ownership filter to employees_select for hire pipeline
-- =============================================================================
--
-- PROBLEM
-- ───────
-- The hire-pipeline branch of employees_select (mig 219) uses only
-- user_can('hire_employee', 'view', NULL) as its gate. This lets ANY HR Analyst
-- with hire_employee.view read every other analyst's Draft / Incomplete /
-- Pending / Rejected record — regardless of whether they have the
-- "Pipeline visibility" (view_all_pending) permission.
--
-- The UPDATE policy (mig 256) already has the correct ownership pattern for
-- Draft/Incomplete. This migration applies the same pattern for SELECT on
-- Draft/Incomplete/Rejected, while keeping Pending fully open to any
-- hire_employee.view holder so workflow approvers are not blocked.
--
-- ROOT CAUSE ANALYSIS
-- ───────────────────
-- Mig 219 opened SELECT for ALL pipeline statuses with Path B (no target-group
-- cache). The oversight: it did not apply the ownership filter that mig 256
-- added for UPDATE. Any analyst with hire_employee.view could read every other
-- analyst's Draft/Incomplete/Pending/Rejected record.
--
-- WHY PENDING MUST REMAIN OPEN
-- ─────────────────────────────
-- WorkflowReview does a direct employees.SELECT to load the hire record name
-- and metadata (line ~904 in WorkflowReview.tsx). The approver can be any
-- manager or HR user — they have hire_employee.view but NOT necessarily
-- view_all_pending. Applying the ownership filter to Pending would block
-- approvers from reading the record they are assigned to approve.
-- SECURITY DEFINER RPCs (update_hire_field, validate_hire_fields, etc.) bypass
-- RLS, but the initial metadata fetch is a plain SELECT.
--
-- FIX — split pipeline statuses into two branches:
-- ─────
--   Draft / Incomplete / Rejected  → ownership filter (own record, view_all_pending,
--                                     super admin, or legacy NULL)
--   Pending                        → any hire_employee.view (same as mig 219)
--
-- BLAST-RADIUS AUDIT
-- ──────────────────
-- ✓ Active / Inactive employees — unchanged branches; no behaviour change
-- ✓ Creator analyst — sees own Draft/Incomplete/Rejected via created_by = auth.uid()
-- ✓ HR Analyst (no view_all_pending) — sees only own drafts; cannot see peers' drafts
-- ✓ HR Head (view_all_pending) — sees all pipeline records via view_all_pending
-- ✓ Super admin — is_super_admin() bypass; unchanged access
-- ✓ Legacy pre-mig-253 records (created_by IS NULL) — NULL bypass; visible to
--   any analyst with hire_employee.view (same as before)
-- ✓ Workflow approver (manager, HR Head) — reads Pending record freely via
--   hire_employee.view; not blocked by ownership filter
-- ✓ Creator tracks own submitted (Pending) hire — created_by = auth.uid()
--   also passes the Pending branch's hire_employee.view gate
-- ✓ SECURITY DEFINER RPCs (validate_hire_fields, update_hire_field,
--   wf_submit, wf_activate_employee, get_hire_submission_mode) — bypass RLS
-- ✓ ESS / MyProfile — reads own Active employee row; unaffected branch
-- ✓ useEmployees hook — RLS now returns only own Draft/Incomplete/Rejected
--   plus all Pending records to each analyst
-- =============================================================================

DROP POLICY IF EXISTS employees_select ON employees;

CREATE POLICY employees_select ON employees FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      -- ── Active employees ─────────────────────────────────────────────────
      -- target-group scoped; Path D (employee UUID as owner)
      (status = 'Active'
        AND user_can('employee_details', 'view', id))

      -- ── Inactive employees ───────────────────────────────────────────────
      OR (status = 'Inactive'
          AND user_can('inactive_employees', 'view', id))

      -- ── Hire pipeline: Draft / Incomplete / Rejected ─────────────────────
      -- Still being authored or sent back to creator — apply ownership filter.
      -- Ownership: creator OR HR Head (view_all_pending) OR super admin.
      -- Legacy records (created_by IS NULL, pre-mig 253) remain visible to any
      -- analyst with hire_employee.view so old data is not orphaned.
      OR (status IN ('Draft', 'Incomplete', 'Rejected')
          AND user_can('hire_employee', 'view', NULL)
          AND (
            created_by IS NULL                                         -- legacy
            OR created_by = auth.uid()                                 -- own record
            OR user_can('hire_employee', 'view_all_pending', NULL)     -- HR Head
            OR is_super_admin()
          ))

      -- ── Hire pipeline: Pending ───────────────────────────────────────────
      -- Submitted for approval — any hire_employee.view holder can read.
      -- This is intentionally open: the workflow approver (manager, HR user)
      -- needs a direct employees.SELECT to load the record in WorkflowReview.
      -- The UPDATE policy (mig 256) separately restricts who can mutate it.
      OR (status = 'Pending'
          AND user_can('hire_employee', 'view', NULL))
    )
  );

COMMENT ON POLICY employees_select ON employees IS
  'Status-routed SELECT. '
  'Active: employee_details.view (target-group scoped). '
  'Inactive: inactive_employees.view. '
  'Draft/Incomplete/Rejected: hire_employee.view + ownership (own OR view_all_pending OR super admin OR legacy NULL). '
  'Pending: hire_employee.view only — kept open so workflow approvers can read the record. '
  'Mig 416: ownership filter on draft pipeline; Pending deliberately unrestricted for approver access.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  tablename  = 'employees'
      AND  policyname = 'employees_select'
      AND  cmd        = 'SELECT'
  ) THEN
    RAISE EXCEPTION 'ABORT: employees_select policy not found after migration 416.';
  END IF;
  RAISE NOTICE 'Migration 416 verified: employees_select policy present with ownership filter.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 20260602415_hire_pipeline_select_ownership.sql
-- =============================================================================
