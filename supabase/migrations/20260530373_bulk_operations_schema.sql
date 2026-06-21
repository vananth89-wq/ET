-- =============================================================================
-- Migration 368 — Bulk Operations Framework: Core Schema
--
-- Introduces the registry-driven cross-module Import / Export framework.
-- All 24 locked rules are implemented through this schema + the Edge Functions.
--
-- Changes:
--   1. Create bulk_template_registry  (one row per module/template)
--   2. Create bulk_upload_job         (per-upload tracker)
--   3. updated_at triggers on both tables
--   4. user_has_any_bulk_permission() visibility-gate function (must precede storage RLS)
--   5. Storage bucket bulk-uploads    (private, 7-day retention via cron)
--   6. Storage RLS policies           (uploader + System Admin)
--   7. RLS on both tables
--   7. updated_at trigger on both tables
--
-- Design spec: docs/bulk-operations-framework.md §3–§7
-- Predecessor: mig 367 (bank_accounts permissions)
-- Next: mig 369 (permission seeds), mig 370 (registry seeds)
-- =============================================================================


-- =============================================================================
-- 1. bulk_template_registry
-- =============================================================================

CREATE TABLE IF NOT EXISTS bulk_template_registry (
  template_code          TEXT        PRIMARY KEY,
  display_label          TEXT        NOT NULL,
  description            TEXT        NOT NULL,
  icon                   TEXT        NOT NULL DEFAULT 'ti-table-import',
  sort_order             INTEGER     NOT NULL DEFAULT 100,
  is_active              BOOLEAN     NOT NULL DEFAULT true,

  -- Permissions (codes from the permissions table)
  permission_import      TEXT        NOT NULL,
  permission_export      TEXT        NOT NULL,

  -- Processor RPCs
  processor_rpc          TEXT        NOT NULL,
  deleter_rpc            TEXT,
  exporter_query         TEXT        NOT NULL,
  history_exporter_query TEXT,

  -- Column schema drives template generator, exporter, importer
  schema_definition      JSONB       NOT NULL,

  -- Behaviour flags
  workflow_bypass        BOOLEAN     NOT NULL DEFAULT true,
  natural_key            TEXT[]      NOT NULL,

  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE bulk_template_registry IS
  'Cross-module Bulk Operations Framework. One row per supported import/export template. '
  'UI, Edge Functions, and Permission Matrix all read this table. '
  'See docs/bulk-operations-framework.md for the full spec and 24 locked rules.';

COMMENT ON COLUMN bulk_template_registry.schema_definition IS
  'JSONB array of column descriptors. Each element: {name, data_type, mandatory, user_fillable, description?, include_with_system_metadata?, computed_from?}. '
  'Drives template CSV generation, export column selection, and import validation. See §5 of the design spec.';

COMMENT ON COLUMN bulk_template_registry.workflow_bypass IS
  'Always true per locked rule 13 — bulk uploads bypass workflow regardless of per-module config.';

COMMENT ON COLUMN bulk_template_registry.exporter_query IS
  'SQL snippet (a SELECT statement body) used by the bulk_export_generator Edge Function. '
  'Should produce rows with column names matching schema_definition.columns[].name.';


-- =============================================================================
-- 2. bulk_upload_job
-- =============================================================================

CREATE TABLE IF NOT EXISTS bulk_upload_job (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  template_code     TEXT        NOT NULL REFERENCES bulk_template_registry(template_code),
  uploaded_by       UUID        NOT NULL REFERENCES profiles(id) ON DELETE SET NULL,
  uploaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  file_name         TEXT        NOT NULL,
  storage_path      TEXT        NOT NULL,
  row_count         INTEGER     NOT NULL,

  -- Pre-process counts
  valid_count       INTEGER,
  warning_count     INTEGER,
  error_count       INTEGER,

  -- Processing results
  processed_count   INTEGER     NOT NULL DEFAULT 0,
  succeeded_count   INTEGER     NOT NULL DEFAULT 0,
  failed_count      INTEGER     NOT NULL DEFAULT 0,
  skipped_count     INTEGER     NOT NULL DEFAULT 0,

  status            TEXT        NOT NULL
                    CHECK (status IN (
                      'validating',
                      'awaiting_user',
                      'processing',
                      'completed',
                      'partial',
                      'cancelled',
                      'failed'
                    ))
                    DEFAULT 'validating',

  cancelled_at      TIMESTAMPTZ,
  cancelled_by      UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  completed_at      TIMESTAMPTZ,
  error_file_path   TEXT,
  notification_sent BOOLEAN     NOT NULL DEFAULT false,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE bulk_upload_job IS
  'Tracks every bulk upload attempt — in-flight, completed, cancelled, or failed. '
  'Drives the Recent Uploads panel and the async Edge Function status polling.';

COMMENT ON COLUMN bulk_upload_job.status IS
  'validating: pre-process underway | awaiting_user: validation done, waiting for user to click Process | '
  'processing: async Edge Function running | completed: all rows succeeded | partial: some rows failed | '
  'cancelled: user cancelled (committed rows stay) | failed: catastrophic failure.';

COMMENT ON COLUMN bulk_upload_job.storage_path IS
  'Path in the bulk-uploads Storage bucket: bulk-uploads/{id}.csv';

COMMENT ON COLUMN bulk_upload_job.error_file_path IS
  'Optional — bulk-uploads/{id}_errors.csv written after partial/failed processing.';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_buj_uploader
  ON bulk_upload_job (uploaded_by, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_buj_template
  ON bulk_upload_job (template_code, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_buj_status_active
  ON bulk_upload_job (status)
  WHERE status IN ('validating', 'awaiting_user', 'processing');


-- =============================================================================
-- 3. updated_at triggers
-- =============================================================================

-- Reuse existing helper if present, otherwise create a simple one
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_bulk_template_registry_updated_at
  BEFORE UPDATE ON bulk_template_registry
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE TRIGGER trg_bulk_upload_job_updated_at
  BEFORE UPDATE ON bulk_upload_job
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- 4. user_has_any_bulk_permission() — sidebar visibility gate
-- (defined before storage RLS policies that reference it)
-- =============================================================================

CREATE OR REPLACE FUNCTION user_has_any_bulk_permission(
  p_profile_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   permissions p
    WHERE  p.code ~ '\.bulk_(import|export)$'
      AND  user_can(
             split_part(p.code, '.', 1),
             split_part(p.code, '.', 2),
             NULL
           )
  );
$$;

COMMENT ON FUNCTION user_has_any_bulk_permission IS
  'Returns true if the calling user has at least one *.bulk_import or *.bulk_export permission. '
  'Used as the sidebar visibility gate for the Import / Export nav item.';

GRANT EXECUTE ON FUNCTION user_has_any_bulk_permission(UUID) TO authenticated;


-- =============================================================================
-- 5. Storage bucket: bulk-uploads
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'bulk-uploads',
  'bulk-uploads',
  false,        -- private — access via signed URLs only
  52428800,     -- 50 MB per file (10k rows × ~5 KB/row headroom)
  ARRAY['text/csv', 'text/plain', 'application/octet-stream', 'application/zip']
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Storage RLS
DROP POLICY IF EXISTS bulk_uploads_insert ON storage.objects;
DROP POLICY IF EXISTS bulk_uploads_select ON storage.objects;
DROP POLICY IF EXISTS bulk_uploads_delete ON storage.objects;

-- Upload: any authenticated user with at least one bulk_import permission
CREATE POLICY bulk_uploads_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'bulk-uploads'
    AND auth.uid() IS NOT NULL
    AND user_has_any_bulk_permission()
  );

-- Download: uploader can read their own files; System Admin reads all
CREATE POLICY bulk_uploads_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'bulk-uploads'
    AND (
      -- uploader owns this job
      EXISTS (
        SELECT 1
        FROM   public.bulk_upload_job j
        WHERE  j.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
          AND  j.uploaded_by  = auth.uid()
      )
      -- or user is System Admin
      OR public.is_super_admin()
    )
  );

-- Delete: only via 7-day retention cron; no user-driven deletes
CREATE POLICY bulk_uploads_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'bulk-uploads'
    AND public.is_super_admin()
  );


-- =============================================================================
-- 6. RLS on bulk_template_registry and bulk_upload_job
-- =============================================================================

-- bulk_template_registry: read-only for authenticated users
ALTER TABLE bulk_template_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bulk_registry_select ON bulk_template_registry;
CREATE POLICY bulk_registry_select ON bulk_template_registry FOR SELECT
  USING (auth.uid() IS NOT NULL AND is_active = true);

-- Admins can manage registry rows directly (mig-driven inserts bypass RLS anyway)
DROP POLICY IF EXISTS bulk_registry_admin ON bulk_template_registry;
CREATE POLICY bulk_registry_admin ON bulk_template_registry FOR ALL
  USING (public.is_super_admin());


-- bulk_upload_job: uploader sees own rows; System Admin sees all
ALTER TABLE bulk_upload_job ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bulk_job_select ON bulk_upload_job;
CREATE POLICY bulk_job_select ON bulk_upload_job FOR SELECT
  USING (
    uploaded_by = auth.uid()
    OR public.is_super_admin()
  );

DROP POLICY IF EXISTS bulk_job_insert ON bulk_upload_job;
CREATE POLICY bulk_job_insert ON bulk_upload_job FOR INSERT
  WITH CHECK (
    uploaded_by = auth.uid()
    AND user_has_any_bulk_permission()
  );

DROP POLICY IF EXISTS bulk_job_update ON bulk_upload_job;
CREATE POLICY bulk_job_update ON bulk_upload_job FOR UPDATE
  USING (
    -- uploader can cancel their own in-flight job
    (uploaded_by = auth.uid() AND status IN ('validating', 'awaiting_user', 'processing'))
    OR public.is_super_admin()
  );


-- =============================================================================
-- 7. Verification
-- =============================================================================

SELECT
  table_name,
  (SELECT COUNT(*) FROM information_schema.columns c
   WHERE c.table_name = t.table_name AND c.table_schema = 'public') AS col_count
FROM (VALUES ('bulk_template_registry'), ('bulk_upload_job')) AS t(table_name);

SELECT id, name, public FROM storage.buckets WHERE id = 'bulk-uploads';

SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'user_has_any_bulk_permission';

-- =============================================================================
-- END OF MIGRATION 368
-- =============================================================================
