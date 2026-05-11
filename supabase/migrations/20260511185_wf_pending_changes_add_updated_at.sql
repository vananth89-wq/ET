-- =============================================================================
-- Migration 185: Add updated_at to workflow_pending_changes
--
-- Migration 181 patched wf_resubmit to SET updated_at = now() when
-- p_proposed_data is provided, but the column was never added to the table.
-- This caused:
--   column "updated_at" of relation "workflow_pending_changes" does not exist
-- whenever wf_resubmit was called with a non-null p_proposed_data.
--
-- Fix: add the column with a sensible default so existing rows get a value
-- and the UPDATE in wf_resubmit succeeds.
-- =============================================================================

ALTER TABLE workflow_pending_changes
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- Back-fill existing rows: treat created_at as the last update time
UPDATE workflow_pending_changes
SET    updated_at = created_at
WHERE  updated_at IS NULL;

COMMENT ON COLUMN workflow_pending_changes.updated_at IS
  'Set by wf_resubmit when the submitter updates proposed_data after a '
  'clarification request. NULL on initial submission.';


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_name  = 'workflow_pending_changes'
  AND  column_name = 'updated_at';

-- =============================================================================
-- END OF MIGRATION 185
-- =============================================================================
