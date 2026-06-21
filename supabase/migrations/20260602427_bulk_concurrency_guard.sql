-- =============================================================================
-- Migration 427 — Bulk import concurrency guard
--
-- Prevents two admins from processing the same template simultaneously.
-- Uses an advisory-lock pattern via three new columns on bulk_template_registry
-- plus two RPCs: acquire_bulk_lock / release_bulk_lock.
--
-- The Edge Function calls acquire_bulk_lock before processing and
-- release_bulk_lock on completion/failure/cancellation.
-- A stale lock (> 30 min) is auto-expired by the acquire RPC so a crashed job
-- never permanently blocks a template.
--
-- Predecessor: mig 426 (bulk_job_log)
-- =============================================================================

ALTER TABLE bulk_template_registry
  ADD COLUMN IF NOT EXISTS processing_lock    BOOLEAN      NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS locked_by_job_id   UUID         REFERENCES bulk_upload_job(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS locked_at          TIMESTAMPTZ;


-- =============================================================================
-- RPC: acquire_bulk_lock
-- Called at the start of processing. Returns {ok, error}.
-- Auto-expires stale locks older than 30 minutes.
-- =============================================================================

CREATE OR REPLACE FUNCTION acquire_bulk_lock(
  p_template_code TEXT,
  p_job_id        UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lock_job_id UUID;
  v_locked_at   TIMESTAMPTZ;
BEGIN
  -- Read current lock state
  SELECT locked_by_job_id, locked_at
  INTO   v_lock_job_id, v_locked_at
  FROM   bulk_template_registry
  WHERE  template_code = p_template_code
  FOR UPDATE;  -- row-level lock prevents race condition

  -- If locked by another job and lock is fresh (< 30 min), reject
  IF v_lock_job_id IS NOT NULL
     AND v_lock_job_id <> p_job_id
     AND v_locked_at > NOW() - INTERVAL '30 minutes'
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'Another import is already running for this template (job %s, started %s). '
        'Wait for it to complete or try again in a few minutes.',
        v_lock_job_id,
        TO_CHAR(v_locked_at, 'HH24:MI')
      )
    );
  END IF;

  -- Acquire (or steal stale) lock
  UPDATE bulk_template_registry
  SET    processing_lock  = true,
         locked_by_job_id = p_job_id,
         locked_at        = NOW(),
         updated_at       = NOW()
  WHERE  template_code = p_template_code;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION acquire_bulk_lock(TEXT, UUID) TO authenticated;
COMMENT ON FUNCTION acquire_bulk_lock IS
  'Acquire processing lock for a template before bulk import. '
  'Stale locks (> 30 min) are auto-expired. Returns {ok, error}.';


-- =============================================================================
-- RPC: release_bulk_lock
-- Called when processing completes, fails, or is cancelled.
-- Only the job that holds the lock can release it (or a super_admin).
-- =============================================================================

CREATE OR REPLACE FUNCTION release_bulk_lock(
  p_template_code TEXT,
  p_job_id        UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE bulk_template_registry
  SET    processing_lock  = false,
         locked_by_job_id = NULL,
         locked_at        = NULL,
         updated_at       = NOW()
  WHERE  template_code    = p_template_code
    AND  (locked_by_job_id = p_job_id OR (SELECT is_super_admin()));

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION release_bulk_lock(TEXT, UUID) TO authenticated;
COMMENT ON FUNCTION release_bulk_lock IS
  'Release processing lock for a template after bulk import completes/fails.';

-- =============================================================================
-- END OF MIGRATION 427
-- =============================================================================
