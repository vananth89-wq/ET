-- =============================================================================
-- Migration 123: Drop orphaned legacy RLS policies on expense_reports & line_items
--
-- BACKGROUND
-- ──────────
-- Migration 084 (rbp_phase3_user_can_rls) introduced rbp_* replacement policies
-- on expense_reports and line_items that use user_can() for enforcement.
-- The old has_role()-based policies were never explicitly dropped, leaving both
-- sets active simultaneously. Postgres ORs all policies per operation, meaning
-- the old policies are granting unintended bypass access alongside the new ones.
--
-- WHAT IS DROPPED
-- ───────────────
--   expense_reports  → expense_reports_select, _insert, _update, _delete
--   line_items       → line_items_select, _insert, _update, _delete
--
-- WHAT REMAINS (unchanged)
-- ────────────────────────
--   expense_reports  → rbp_expense_reports_select, _insert, _update, _delete
--   line_items       → rbp_line_items_select, _insert, _update, _delete
--
-- RISK: Very low — the rbp_* policies fully cover all operations and have been
-- coexisting since migration 084. This drop removes only the redundant bypass.
-- =============================================================================


-- ── expense_reports: drop 4 legacy policies ───────────────────────────────────

DROP POLICY IF EXISTS expense_reports_select ON expense_reports;
DROP POLICY IF EXISTS expense_reports_insert ON expense_reports;
DROP POLICY IF EXISTS expense_reports_update ON expense_reports;
DROP POLICY IF EXISTS expense_reports_delete ON expense_reports;


-- ── line_items: drop 4 legacy policies ───────────────────────────────────────

DROP POLICY IF EXISTS line_items_select ON line_items;
DROP POLICY IF EXISTS line_items_insert ON line_items;
DROP POLICY IF EXISTS line_items_update ON line_items;
DROP POLICY IF EXISTS line_items_delete ON line_items;


-- ── Verification ──────────────────────────────────────────────────────────────
-- Expected: only rbp_* policies remain on both tables

SELECT
  tablename,
  policyname,
  cmd
FROM pg_policies
WHERE tablename IN ('expense_reports', 'line_items')
ORDER BY tablename, cmd, policyname;
