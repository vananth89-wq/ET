-- =============================================================================
-- Migration 141: Upgrade job_run_log RLS to user_can()
--
-- BACKGROUND
-- ──────────
-- job_run_log has a single FOR ALL policy gated on:
--   has_role('admin') OR has_permission('workflow.admin')
-- Rows are written exclusively by pg_cron / SECURITY DEFINER job functions
-- and are read-only for humans. The FOR ALL write coverage is unnecessary —
-- we replace it with a SELECT-only admin read policy.
--
-- jobs_manage.view already exists (seeded in migration 091).
-- =============================================================================


DROP POLICY IF EXISTS job_run_log_admin ON job_run_log;

-- Admin monitoring only — rows written by internal job functions (SECURITY DEFINER).
CREATE POLICY job_run_log_select ON job_run_log FOR SELECT
  USING (user_can('jobs_manage', 'view', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'job_run_log'
ORDER BY cmd, policyname;
