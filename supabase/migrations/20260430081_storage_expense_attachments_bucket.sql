-- =============================================================================
-- Migration 081: Create expense-attachments storage bucket + RLS policies
--
-- WHY
-- ═══
-- addAttachment() uploads to the 'expense-attachments' bucket, then calls
-- createSignedUrl() which requires SELECT on storage.objects.
-- Without the bucket existing + storage RLS policies, createSignedUrl() returns
-- "Object not found" (400) even when the file was uploaded successfully.
--
-- APPROACH
-- ════════
-- Security is enforced at the DB layer (attachments_insert RLS → can_write_module_record).
-- Storage policies just gate access by bucket + authentication, keeping them
-- simple and not duplicating business logic in two places.
-- =============================================================================

-- ── 1. Create the bucket (no-op if it already exists) ─────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'expense-attachments',
  'expense-attachments',
  false,
  5242880,   -- 5 MB
  ARRAY['image/jpeg','image/png','image/gif','image/webp','application/pdf']
)
ON CONFLICT (id) DO NOTHING;


-- ── 2. DROP any stale policies first (idempotent) ─────────────────────────────
DROP POLICY IF EXISTS "expense_attach_insert" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_select" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_delete" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_update" ON storage.objects;


-- ── 3. INSERT — any authenticated user may upload ─────────────────────────────
-- DB-level RLS (attachments_insert → can_write_module_record) enforces who may
-- actually create an attachment record; storage just checks authentication.
CREATE POLICY "expense_attach_insert"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'expense-attachments');


-- ── 4. SELECT — any authenticated user may read / sign URLs ───────────────────
-- Required for createSignedUrl(). Signed URLs expire in 1 hour.
CREATE POLICY "expense_attach_select"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'expense-attachments');


-- ── 5. DELETE — any authenticated user may remove objects ─────────────────────
-- DB-layer handles permission checks before calling storage.remove().
CREATE POLICY "expense_attach_delete"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'expense-attachments');


-- ── VERIFICATION ──────────────────────────────────────────────────────────────
SELECT id, name, public, file_size_limit FROM storage.buckets WHERE id = 'expense-attachments';

SELECT policyname, cmd
FROM   pg_policies
WHERE  tablename  = 'objects'
  AND  schemaname = 'storage'
  AND  policyname LIKE 'expense_attach%'
ORDER  BY cmd;
