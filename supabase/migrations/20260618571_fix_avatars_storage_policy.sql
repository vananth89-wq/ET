-- Fix avatars storage RLS policies.
-- The original migration (20260425029) used has_role('admin') which does not
-- exist in this codebase. Replace with is_super_admin() which is the standard
-- Prowess super-admin check.

DROP POLICY IF EXISTS storage_avatars_insert ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_update ON storage.objects;
DROP POLICY IF EXISTS storage_avatars_delete ON storage.objects;

-- INSERT: own folder OR super-admin
CREATE POLICY storage_avatars_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid() IS NOT NULL
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  );

-- UPDATE (upsert): same rule
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

-- DELETE: own folder OR super-admin
CREATE POLICY storage_avatars_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND (
      (storage.foldername(name))[2] = public.get_my_employee_id()::text
      OR public.is_super_admin()
    )
  );
