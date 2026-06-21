-- =============================================================================
-- Migration 343 — Fix hr-attachments SELECT policy for dependent attachments
-- =============================================================================
--
-- BUG
-- ───
-- storage_hr_att_select (mig 276) only allows createSignedUrl / GET when the
-- storage path matches a row in employee_bank_attachments. That table never
-- contains dependent attachment paths, so every createSignedUrl call for
-- dependent documents fails with:
--
--   POST .../storage/v1/object/sign/hr-attachments/dependents/... → 400 Bad Request
--
-- PATH FORMAT DIFFERENCE
-- ──────────────────────
-- Bank:      employee_bank_attachments.storage_path
--              = 'hr-attachments/bank-accounts/{emp_id}/{group_id}/{file}'
--              (bucket prefix included)
--            → policy compares: a.storage_path = (bucket_id || '/' || name)
--
-- Dependents: employee_dependent_attachments.file_path
--              = 'dependents/{emp_id}/{dep_code}/{file}'
--              (NO bucket prefix — bucket-relative path only)
--            → policy must compare: a.file_path = storage.objects.name
--
-- FIX
-- ───
-- Extend the SELECT policy to also permit access when the path matches an
-- active row in employee_dependent_attachments (using the bucket-relative
-- name column, not the full bucket_id/name concatenation).
-- =============================================================================

DROP POLICY IF EXISTS storage_hr_att_select ON storage.objects;

CREATE POLICY storage_hr_att_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'hr-attachments'
    AND (
      is_super_admin()

      -- Bank attachments: storage_path stored with bucket prefix
      OR EXISTS (
        SELECT 1
        FROM   public.employee_bank_attachments a
        WHERE  a.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
          AND  a.is_active = true
      )

      -- Dependent attachments: file_path stored without bucket prefix
      OR EXISTS (
        SELECT 1
        FROM   public.employee_dependent_attachments a
        WHERE  a.file_path = storage.objects.name
          AND  a.is_active = true
      )
    )
  );
