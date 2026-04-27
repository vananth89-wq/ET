-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Allow all authenticated users to read active employees
--
-- Why: ESS employees need to see the full org chart. The previous policy
-- restricted them to only their own record + direct reports.
--
-- New rule:
--   • Admins  → see all rows (including soft-deleted, for audit/recovery)
--   • Everyone else (ESS, finance, manager, etc.) → see all ACTIVE employees
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "employees_select" ON employees;

CREATE POLICY "employees_select"
  ON employees FOR SELECT
  USING (
    has_role('admin')                                  -- admins see all (incl. deleted)
    OR (deleted_at IS NULL AND auth.uid() IS NOT NULL) -- everyone else sees active only
  );
