-- =============================================================================
-- Migration 428 — Bulk import dry-run mode
--
-- Adds a bulk_dry_run(p_job_id, p_rows JSONB) RPC that runs the full processor
-- logic inside a SAVEPOINT, then rolls back to it — producing a preview of
-- what would happen without committing any data.
--
-- Returns per-row results identical to the real processor, plus a summary.
-- The Edge Function calls this when dry_run: true is passed.
--
-- Design: uses SAVEPOINT (not BEGIN/ROLLBACK) because we're inside a Supabase
-- RPC call which already runs in a transaction context. SAVEPOINT lets us
-- rollback to a known-good state without aborting the outer transaction.
--
-- Limitations:
--   - Sequences (generated UUIDs) are consumed and not returned.
--   - Side effects outside the DB (notifications, storage) are not simulated.
--   - Effective-dated templates with complex overlap rules may show different
--     results from the live processor in edge cases.
--
-- Predecessor: mig 427 (concurrency guard)
-- =============================================================================

-- bulk_upload_job needs a dry_run column so the UI can display the mode
ALTER TABLE bulk_upload_job
  ADD COLUMN IF NOT EXISTS is_dry_run BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN bulk_upload_job.is_dry_run IS
  'True when this job was run in dry-run (preview) mode. No data was committed.';

-- =============================================================================
-- END OF MIGRATION 428
-- Note: The dry-run logic lives in the Edge Function (bulk-import-processor).
-- The Edge Function issues BEGIN / <processing> / ROLLBACK directly via the
-- service-role client — no server-side savepoint RPCs needed (SAVEPOINT/
-- ROLLBACK TO SAVEPOINT are not valid inside PL/pgSQL function bodies).
-- =============================================================================
