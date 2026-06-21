-- =============================================================================
-- Migration 426 — bulk_job_log table + get_bulk_job_log RPC
--
-- The audit trail for bulk imports was designed but never implemented.
-- This migration creates a dedicated log table and an RPC to query it.
-- The processor Edge Function writes one row per processed CSV row.
--
-- Design decision: we store the natural key + action only (not full before/after
-- diff). This gives compliance-grade traceability ("which records were touched by
-- this import job") without the cost of reading existing rows before every upsert.
-- Full before/after diff can be layered on top later.
--
-- Predecessor: mig 425 (codes not labels)
-- =============================================================================

CREATE TABLE IF NOT EXISTS bulk_job_log (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id       UUID         NOT NULL REFERENCES bulk_upload_job(id) ON DELETE CASCADE,
  row_number   INT          NOT NULL,
  action       TEXT         NOT NULL CHECK (action IN ('created','updated','failed','skipped')),
  natural_key  JSONB        NOT NULL,   -- {column_name: value, ...} from CSV natural key columns
  error        TEXT,                    -- error message for failed rows
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE bulk_job_log IS
  'Per-row audit trail for bulk import jobs. One row per CSV row processed. '
  'natural_key stores the row identity. Written by bulk-import-processor Edge Function.';

CREATE INDEX idx_bulk_job_log_job_id ON bulk_job_log (job_id);

-- RLS: uploader and super_admin can read their own job logs
ALTER TABLE bulk_job_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY bjl_select ON bulk_job_log FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM bulk_upload_job buj
    WHERE buj.id = bulk_job_log.job_id
      AND (
        buj.uploaded_by = auth.uid()
        OR (SELECT is_super_admin())
      )
  )
);

CREATE POLICY bjl_insert ON bulk_job_log FOR INSERT WITH CHECK (true);


-- =============================================================================
-- RPC: get_bulk_job_log
-- Returns the log for a given job, ordered by row_number.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_bulk_job_log(p_job_id UUID)
RETURNS TABLE (
  row_number  INT,
  action      TEXT,
  natural_key JSONB,
  error       TEXT,
  created_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT l.row_number, l.action, l.natural_key, l.error, l.created_at
  FROM   bulk_job_log l
  JOIN   bulk_upload_job j ON j.id = l.job_id
  WHERE  l.job_id = p_job_id
    AND  (
      j.uploaded_by = auth.uid()
      OR (SELECT is_super_admin())
    )
  ORDER  BY l.row_number;
$$;

GRANT EXECUTE ON FUNCTION get_bulk_job_log(UUID) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 426
-- =============================================================================
