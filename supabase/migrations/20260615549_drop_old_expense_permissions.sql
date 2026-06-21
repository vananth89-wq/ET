-- =============================================================================
-- Migration 549 — Delete legacy expense.* permissions
--
-- The old expense.* permission codes (expense.view_own, expense.create, etc.)
-- were replaced by expense_reports.* codes which are now fully assigned to
-- roles via permission sets.
--
-- Frontend gates migrated:
--   can('expense.export')          → can('expense_reports.view')  [AdminReports.tsx]
--   can('expense.view_org')        → can('expense_reports.view')  [ExpenseAnalytics.tsx]
--   canAny(['expense.view_direct', 'expense.view_team']) → can('expense_reports.view')
--
-- Safe: expense.* codes have NO permission_set_items rows (never assigned to any
-- role via permission sets), so CASCADE on permission_set_items is a no-op.
-- =============================================================================

DELETE FROM permissions
WHERE  code LIKE 'expense.%';

-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM permissions WHERE code LIKE 'expense.%'
  ), 'legacy expense.* permissions still exist after deletion';

  RAISE NOTICE 'Mig 549: all legacy expense.* permissions removed.';
END;
$$;
