-- =============================================================================
-- Migration 080: Fix NULL write_permission in module_registry
--
-- ROOT CAUSE
-- ══════════
-- module_registry.write_permission and approval_write_permission were never
-- populated (both NULL). can_write_module_record() checks these at the top of
-- every path:
--
--   Path 1: IF v_reg.write_permission IS NOT NULL ...
--   Path 2: IF v_reg.approval_write_permission IS NOT NULL ...
--   Path 3: IF v_reg.write_permission IS NOT NULL ...
--
-- With both columns NULL, all three paths short-circuit to false, causing:
--   • attachments_insert to return 403 for ALL expense reports (draft, rejected,
--     submitted, awaiting_clarification)
--   • can_write_module_record to always return false regardless of user/status
--
-- FIX
-- ═══
-- Populate write_permission and approval_write_permission for expense_reports.
-- This unblocks Path 1 (owner writes on draft/rejected), Path 2 (approver
-- writes on submitted+), and Path 3 (owner writes when awaiting_clarification).
-- =============================================================================

UPDATE module_registry
SET
  write_permission              = 'expense.edit',
  approval_write_permission     = 'expense.edit_approval',
  approval_writable_statuses    = ARRAY['submitted', 'approved', 'rejected']
WHERE code = 'expense_reports';

-- VERIFICATION
SELECT
  code,
  write_permission,
  writable_statuses,
  approval_write_permission,
  approval_writable_statuses
FROM module_registry
WHERE code = 'expense_reports';
