-- ─────────────────────────────────────────────────────────────────────────────
-- Complete storage bucket coverage — adds the 3 buckets missing from
-- 20260709685 (bulk-uploads, theme, ProwessLogo) plus their RLS policies.
--
-- WHY
-- ═══
-- Task 32 audit found 6 buckets on UAT but only 3 in the earlier bootstrap:
--   Present in 685:  avatars, expense-attachments, hr-attachments
--   Missing:         bulk-uploads (via mig 373), theme (via mig 555),
--                    ProwessLogo (manually created in dashboard — never codified)
--
-- Fresh Local rebuilds were missing these, so bulk imports and theme uploads
-- would fail. This migration is idempotent.
-- ─────────────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Buckets
-- ═════════════════════════════════════════════════════════════════════════════

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('bulk-uploads',  'bulk-uploads',  false, 52428800,
   ARRAY['text/csv','text/plain','application/octet-stream','application/zip']),
  ('theme',         'theme',         true,  NULL, NULL),
  ('ProwessLogo',   'ProwessLogo',   true,  NULL, NULL)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Fix expense-attachments MIME types drift (bootstrap had extra image/gif)
UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp','application/pdf']
 WHERE id = 'expense-attachments';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. bulk-uploads policies (from mig 20260530373)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS bulk_uploads_insert ON storage.objects;
DROP POLICY IF EXISTS bulk_uploads_select ON storage.objects;
DROP POLICY IF EXISTS bulk_uploads_delete ON storage.objects;

CREATE POLICY bulk_uploads_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'bulk-uploads'
    AND auth.uid() IS NOT NULL
    AND public.user_has_any_bulk_permission()
  );

CREATE POLICY bulk_uploads_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'bulk-uploads'
    AND (
      EXISTS (
        SELECT 1 FROM public.bulk_upload_job j
        WHERE j.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
          AND j.uploaded_by  = auth.uid()
      )
      OR public.is_super_admin()
    )
  );

CREATE POLICY bulk_uploads_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'bulk-uploads'
    AND public.is_super_admin()
  );


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. theme policies (from mig 20260617555)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS theme_bucket_read   ON storage.objects;
DROP POLICY IF EXISTS theme_bucket_write  ON storage.objects;
DROP POLICY IF EXISTS theme_bucket_update ON storage.objects;
DROP POLICY IF EXISTS theme_bucket_delete ON storage.objects;

CREATE POLICY "theme_bucket_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'theme');

CREATE POLICY "theme_bucket_write" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'theme');

CREATE POLICY "theme_bucket_update" ON storage.objects
  FOR UPDATE TO authenticated USING (bucket_id = 'theme');

CREATE POLICY "theme_bucket_delete" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'theme');


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. ProwessLogo policies (never codified — inferred from usage: public bucket
--    for the product logo, super-admin manages content)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS prowess_logo_read      ON storage.objects;
DROP POLICY IF EXISTS prowess_logo_superadmin ON storage.objects;

CREATE POLICY prowess_logo_read ON storage.objects
  FOR SELECT USING (bucket_id = 'ProwessLogo');

CREATE POLICY prowess_logo_superadmin ON storage.objects
  FOR ALL TO authenticated
  USING     (bucket_id = 'ProwessLogo' AND public.is_super_admin())
  WITH CHECK (bucket_id = 'ProwessLogo' AND public.is_super_admin());


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Verification
-- ═════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_bucket_count integer;
  v_policy_count integer;
BEGIN
  SELECT count(*) INTO v_bucket_count FROM storage.buckets;
  SELECT count(*) INTO v_policy_count FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects';
  RAISE NOTICE 'Storage state: % buckets total, % policies on storage.objects',
    v_bucket_count, v_policy_count;
END $$;
