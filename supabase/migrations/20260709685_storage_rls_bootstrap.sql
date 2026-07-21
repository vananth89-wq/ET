-- ─────────────────────────────────────────────────────────────────────────────
-- Storage RLS bootstrap — ensure buckets + storage.objects policies are
-- present in every environment (Local Docker, Dev, UAT, future Prod).
--
-- WHY THIS EXISTS
-- ───────────────
-- The pg_dump --schema-only -n public recipe used for setting up Local (and
-- earlier Dev) skips everything outside the public schema. Storage buckets
-- live in storage.buckets and RLS policies attach to storage.objects — both
-- non-public. On a fresh env, uploads fail with:
--   1. "Bucket not found"                          → bucket missing
--   2. "new row violates row-level security policy" → INSERT policy missing
--   3. "invalid response from upstream server"     → storage container issue
--
-- This migration consolidates the FINAL known-good state of storage RLS as of
-- 2026-07-09. It's fully idempotent (DROP IF EXISTS + CREATE, ON CONFLICT).
-- Safe to run on:
--   - fresh Local — creates everything
--   - Dev/UAT — mostly no-ops (state already exists from earlier migrations)
--
-- Source migrations consolidated here:
--   - 20260425012 phase5 storage (expense-attachments — SUPERSEDED by 081)
--   - 20260425029 avatars storage (SUPERSEDED by 618571/572)
--   - 20260430081 expense-attachments (final state)
--   - 20260526276 hr-attachments bucket + INSERT/DELETE policies
--   - 20260605512 hr-attachments SELECT policy fix (SUPERSEDED by 671)
--   - 20260618571 avatars policies fix (uses is_super_admin)
--   - 20260618572 avatars super_admin ALL policy
--   - 20260701671 hr-attachments authenticated read (final state)
--   - 20260709684 our recent bucket bootstrap
-- ─────────────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. BUCKETS
-- ═════════════════════════════════════════════════════════════════════════════

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('avatars',             'avatars',              true,  5242880,
   ARRAY['image/jpeg','image/png','image/webp','image/gif']),
  ('expense-attachments', 'expense-attachments',  false, 10485760,
   ARRAY['image/jpeg','image/png','image/webp','image/gif','application/pdf']),
  ('hr-attachments',      'hr-attachments',       false, 10485760,
   ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. AVATARS BUCKET POLICIES  (public bucket — writes only need policies)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS storage_avatars_insert       ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_update       ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_delete       ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_superadmin   ON storage.objects;

-- Upload: own folder OR super-admin
CREATE POLICY storage_avatars_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  );

-- Replace / upsert: same rule
CREATE POLICY storage_avatars_update ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  );

-- Delete: own folder OR super-admin
CREATE POLICY storage_avatars_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  );

-- Super-admin catch-all (permissive OR combines with above)
CREATE POLICY storage_avatars_superadmin ON storage.objects FOR ALL
  TO authenticated
  USING     (bucket_id = 'avatars' AND public.is_super_admin())
  WITH CHECK (bucket_id = 'avatars' AND public.is_super_admin());


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. EXPENSE-ATTACHMENTS POLICIES  (private bucket, simple auth check)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "expense_attach_insert" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_select" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_delete" ON storage.objects;
DROP POLICY IF EXISTS "expense_attach_update" ON storage.objects;
DROP POLICY IF EXISTS storage_exp_att_insert  ON storage.objects;
DROP POLICY IF EXISTS storage_exp_att_select  ON storage.objects;
DROP POLICY IF EXISTS storage_exp_att_delete  ON storage.objects;

CREATE POLICY "expense_attach_insert" ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'expense-attachments');

CREATE POLICY "expense_attach_select" ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'expense-attachments');

CREATE POLICY "expense_attach_delete" ON storage.objects FOR DELETE
  TO authenticated
  USING (bucket_id = 'expense-attachments');


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. HR-ATTACHMENTS POLICIES  (private bucket, used for bank / dependent /
--                              education / termination attachments)
-- ═════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS storage_hr_att_insert                    ON storage.objects;
DROP POLICY IF EXISTS storage_hr_att_select                    ON storage.objects;
DROP POLICY IF EXISTS storage_hr_att_delete                    ON storage.objects;
DROP POLICY IF EXISTS "hr_attachments_read"                    ON storage.objects;
DROP POLICY IF EXISTS "hr_attachments_owner_read"              ON storage.objects;
DROP POLICY IF EXISTS "Users can read their own uploads"       ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can read uploads"   ON storage.objects;

-- INSERT: authenticated users may upload; RPC-level checks enforce ownership
CREATE POLICY storage_hr_att_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'hr-attachments'
    AND auth.uid() IS NOT NULL
  );

-- SELECT: authenticated users may read (needed for createSignedUrl in
-- approver inbox where reviewer isn't the uploader)
CREATE POLICY "hr_attachments_read" ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'hr-attachments');

-- DELETE: super-admin only (soft-delete via is_active flag is preferred)
CREATE POLICY storage_hr_att_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'hr-attachments'
    AND public.is_super_admin()
  );


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. VERIFICATION
-- ═════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_bucket_count integer;
  v_policy_count integer;
BEGIN
  SELECT count(*) INTO v_bucket_count
  FROM storage.buckets WHERE id IN ('avatars','expense-attachments','hr-attachments');

  SELECT count(*) INTO v_policy_count
  FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects';

  RAISE NOTICE 'Storage bootstrap complete: % buckets, % policies on storage.objects',
    v_bucket_count, v_policy_count;

  IF v_bucket_count < 3 THEN
    RAISE WARNING 'Expected 3 buckets, found %', v_bucket_count;
  END IF;
END $$;
