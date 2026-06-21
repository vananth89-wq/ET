-- =============================================================================
-- Migration 383 — Fix bulk_upload_job INSERT policy: add super_admin bypass
--
-- PROBLEM
-- ───────
-- bulk_job_insert policy requires user_has_any_bulk_permission(), which
-- calls user_can() for every bulk permission row. user_can() Path A checks
-- is_super_admin() — but is_super_admin() reads the super_admins table via
-- a SECURITY DEFINER helper. When called inside an RLS policy during a client
-- INSERT, the call chain works correctly for normal permission-set users but
-- fails for super_admins because the permission catalog check short-circuits
-- before reaching Path A in some execution contexts.
--
-- Simplest fix: add is_super_admin() as an OR condition directly in the
-- INSERT policy, identical to the pattern used on every other write policy.
-- Also apply the same to the storage.objects INSERT policy for bulk-uploads.
--
-- FIX
-- ───
-- Recreate bulk_job_insert with is_super_admin() OR existing check.
-- =============================================================================

DROP POLICY IF EXISTS bulk_job_insert ON bulk_upload_job;
CREATE POLICY bulk_job_insert ON bulk_upload_job FOR INSERT
  WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      is_super_admin()
      OR user_has_any_bulk_permission()
    )
  );

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT policyname, cmd, qual, with_check
FROM   pg_policies
WHERE  tablename = 'bulk_upload_job'
  AND  policyname = 'bulk_job_insert';

-- =============================================================================
-- END OF MIGRATION 383
-- =============================================================================
