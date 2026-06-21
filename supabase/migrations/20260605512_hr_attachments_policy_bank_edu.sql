-- =============================================================================
-- Migration 512 — Fix hr-attachments SELECT policy: bank path + education
--
-- TWO BUGS (identified in mig 512 analysis):
--
-- Bug 1 — Bank path mismatch
--   Files are uploaded as: bank-accounts/{emp_id}/{id}/{file}  (no bucket prefix)
--   stored in employee_bank_attachments.storage_path the same way.
--   But mig 276 policy checks:
--     a.storage_path = (bucket_id || '/' || name)
--     = 'hr-attachments/bank-accounts/...'
--   which never matches the stored value 'bank-accounts/...'
--   → createSignedUrl always returns 400 for bank files.
--
-- Bug 2 — Education not in policy
--   Mig 344 added dependents but forgot education.
--   employee_education_attachments.file_path = 'education/{emp_id}/{stage}/{file}'
--   (no bucket prefix, same convention as dependents)
--   → createSignedUrl always returns 400 for education files.
--
-- FIX: replace the SELECT policy — all three attachment types compare
--      using storage.objects.name (bucket-relative, no prefix).
-- =============================================================================

DROP POLICY IF EXISTS storage_hr_att_select ON storage.objects;

CREATE POLICY storage_hr_att_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'hr-attachments'
    AND (
      is_super_admin()

      -- Bank: file_path stored without bucket prefix (bank-accounts/...)
      OR EXISTS (
        SELECT 1
        FROM   public.employee_bank_attachments a
        WHERE  a.storage_path = storage.objects.name
          AND  a.is_active = true
      )

      -- Dependents: file_path stored without bucket prefix (dependents/...)
      OR EXISTS (
        SELECT 1
        FROM   public.employee_dependent_attachments a
        WHERE  a.file_path = storage.objects.name
          AND  a.is_active = true
      )

      -- Education: file_path stored without bucket prefix (education/...)
      OR EXISTS (
        SELECT 1
        FROM   public.employee_education_attachments a
        WHERE  a.file_path = storage.objects.name
      )
    )
  );

DO $$
BEGIN
  RAISE NOTICE 'Migration 512: hr-attachments SELECT policy updated — bank path fixed (removed bucket prefix), education added.';
END;
$$;
