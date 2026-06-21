-- Additive fix: give super_admins full access to the avatars bucket.
--
-- The original policy (20260425029) used has_role('admin') for the admin bypass,
-- but is_super_admin() checks a completely separate super_admins table and is
-- the mechanism used by platform admins like Vijey. These two are unrelated.
--
-- PostgreSQL permissive policies combine with OR, so adding a new policy that
-- passes for super_admins is sufficient — no existing policies need to change.

CREATE POLICY storage_avatars_superadmin ON storage.objects FOR ALL
  TO authenticated
  USING   (bucket_id = 'avatars' AND public.is_super_admin())
  WITH CHECK (bucket_id = 'avatars' AND public.is_super_admin());
