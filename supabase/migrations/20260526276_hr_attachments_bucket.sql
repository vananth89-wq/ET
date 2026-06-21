-- =============================================================================
-- Migration 276: hr-attachments storage bucket
--
-- Creates a private storage bucket for HR documents that are not expense
-- attachments. Currently used for:
--   bank-accounts/{employee_id}/{group_id}/{filename}  ← employee bank proof
--
-- Path convention keeps employee data isolated by employee_id prefix so
-- RLS policies can enforce row-level access.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'hr-attachments',
  'hr-attachments',
  false,                -- private — access via signed URLs only
  10485760,             -- 10 MB per file
  ARRAY['image/jpeg','image/png','image/webp','application/pdf']
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ── Storage RLS ───────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS storage_hr_att_insert ON storage.objects;
DROP POLICY IF EXISTS storage_hr_att_select ON storage.objects;
DROP POLICY IF EXISTS storage_hr_att_delete ON storage.objects;

-- Upload: any authenticated user can upload (employee_id is in the path;
-- the upsert_bank_account RPC validates ownership before writing the DB row)
CREATE POLICY storage_hr_att_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'hr-attachments'
    AND auth.uid() IS NOT NULL
  );

-- Download: user can access a file if the corresponding bank attachment row
-- is visible to them (employee_bank_attachments RLS already guards this)
CREATE POLICY storage_hr_att_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'hr-attachments'
    AND EXISTS (
      SELECT 1
      FROM   public.employee_bank_attachments a
      WHERE  a.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
        AND  a.is_active = true
    )
  );

-- Delete: admin/HR only via direct storage call; soft-delete (is_active=false)
-- is the preferred path for employees
CREATE POLICY storage_hr_att_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'hr-attachments'
    AND public.has_role('admin')
  );


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT id, name, public FROM storage.buckets WHERE id = 'hr-attachments';

-- =============================================================================
-- END OF MIGRATION 276
-- =============================================================================
