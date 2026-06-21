-- Migration 522: Register 'termination' in module_codes
--
-- The termination module was registered in `modules` (permission registry) during
-- mig 484, but was never inserted into `module_codes` — the table that drives the
-- Workflow Assignments UI and the workflow gate resolver.
--
-- This migration adds the missing row so:
--   1. "Termination" appears in the Manage Assignments module list.
--   2. wf_submit / resolve_workflow_for_submission can resolve a template for it.
--   3. The icon map in WorkflowAssignments.tsx picks up fa-user-slash (added below).
--
-- Pattern: same shape as profile_personal (label, description, edit_route).
-- table_name / owner_column / status_column are NULL — termination has its own
-- submit RPC (submit_termination) rather than the generic wf_submit attachment
-- path, so the module_registry columns are not needed here.
-- =============================================================================

INSERT INTO module_codes (code, label, description, edit_route)
VALUES (
  'termination',
  'Termination',
  'Employee resignation and HR/manager-initiated termination workflow.',
  NULL   -- Pattern B: no standalone edit route; review is inline in WorkflowReview
)
ON CONFLICT (code) DO UPDATE
  SET label       = EXCLUDED.label,
      description = EXCLUDED.description,
      edit_route  = EXCLUDED.edit_route;
