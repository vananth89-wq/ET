-- =============================================================================
-- Avatars Storage Bucket
--
-- Changes:
--   1. Create 'avatars' storage bucket (PUBLIC, 5 MB limit, images only)
--   2. Storage RLS policies on storage.objects
--
-- Path convention: employees/{employee_uuid}/avatar.{ext}
--
-- Public bucket means SELECT (download / getPublicUrl) needs no RLS policy —
-- Supabase serves public bucket objects to anyone with the URL.
-- We only need INSERT / UPDATE / DELETE policies to restrict writes.
-- =============================================================================


-- ── Step 1: Create public storage bucket ─────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,                                               -- public bucket
  5242880,                                            -- 5 MB per file
  ARRAY['image/jpeg','image/png','image/webp','image/gif']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ── Step 2: Storage object RLS ────────────────────────────────────────────────
--
-- Path convention: employees/{employee_uuid}/avatar.{ext}
--   storage.foldername(name) → ARRAY['employees', '{employee_uuid}']
--   so (storage.foldername(name))[2] is the employee UUID segment.
--
-- INSERT (upload):
--   Authenticated user can upload to their own employee folder.
--   Admins can upload to any employee folder (e.g. profile photos set by HR).
--
-- UPDATE (replace / upsert):
--   Same rule as INSERT — needed because the JS client uses { upsert: true }.
--
-- DELETE:
--   User can delete their own avatar OR admin can delete any.

-- Remove any existing policies first
DROP POLICY IF EXISTS storage_avatars_insert ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_update ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_delete ON storage.objects;

-- Upload: authenticated users can write to their own employee folder,
-- or admins can write to any folder
CREATE POLICY storage_avatars_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.has_role('admin')
    )
  );

-- Replace / upsert: same rule as INSERT
CREATE POLICY storage_avatars_update ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.has_role('admin')
    )
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.has_role('admin')
    )
  );

-- Delete: own folder OR admin
CREATE POLICY storage_avatars_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.has_role('admin')
    )
  );


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT id, name, public, file_size_limit, allowed_mime_types
FROM storage.buckets
WHERE id = 'avatars';

SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'objects' AND schemaname = 'storage'
  AND policyname LIKE 'storage_avatars%';
