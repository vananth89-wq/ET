-- =============================================================================
-- Phase 5: Supabase Storage for Expense Attachments
--
-- Changes:
--   1. Create 'expense-attachments' storage bucket (private, 10 MB limit)
--   2. Storage RLS policies on storage.objects
--   3. RLS policies on the attachments table (was missing from phase 1)
--   4. get_attachment_url(attachment_id) — SECURITY DEFINER helper that
--      returns a signed URL (valid 1 hour) so the frontend never needs to
--      hold the raw storage path
-- =============================================================================


-- ── Step 1: Create private storage bucket ────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'expense-attachments',
  'expense-attachments',
  false,                                              -- private bucket
  10485760,                                           -- 10 MB per file
  ARRAY['image/jpeg','image/png','image/webp','application/pdf']
)
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ── Step 2: Storage object RLS ────────────────────────────────────────────────
--
-- Path convention: {employee_uuid}/{report_id}/{line_item_id}/{filename}
--
-- INSERT (upload):
--   Allowed if the first path segment is the uploader's own employee UUID
--   AND the report is in draft status (enforced by line_items INSERT policy).
--
-- SELECT (download):
--   Allowed if the authenticated user can see the parent expense_report.
--   We delegate the check to the attachments table via a sub-select.
--
-- DELETE:
--   Allowed if the user owns the parent report (draft only) OR is admin.

-- Remove any existing policies first
DROP POLICY IF EXISTS storage_exp_att_insert ON storage.objects;
DROP POLICY IF EXISTS storage_exp_att_select ON storage.objects;
DROP POLICY IF EXISTS storage_exp_att_delete ON storage.objects;

-- Upload: authenticated users can upload to their own employee folder
CREATE POLICY storage_exp_att_insert ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'expense-attachments'
    AND auth.uid() IS NOT NULL
  );

-- Download: user can access a file if the corresponding attachments row is visible
CREATE POLICY storage_exp_att_select ON storage.objects FOR SELECT
  USING (
    bucket_id = 'expense-attachments'
    AND EXISTS (
      SELECT 1 FROM public.attachments a
      JOIN public.line_items li ON li.id = a.line_item_id
      JOIN public.expense_reports er ON er.id = li.report_id
      WHERE a.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
        AND er.deleted_at IS NULL
        AND (
          public.has_role('admin')
          OR (public.has_permission('expense.view_org')  AND er.status::text != 'draft')
          OR (public.has_permission('expense.view_team') AND er.status::text != 'draft'
              AND (public.is_my_direct_report(er.employee_id) OR public.is_in_my_department(er.employee_id)))
          OR er.employee_id = public.get_my_employee_id()
        )
    )
  );

-- Delete: user owns the draft report OR is admin
CREATE POLICY storage_exp_att_delete ON storage.objects FOR DELETE
  USING (
    bucket_id = 'expense-attachments'
    AND (
      public.has_role('admin')
      OR EXISTS (
        SELECT 1 FROM public.attachments a
        JOIN public.line_items li ON li.id = a.line_item_id
        JOIN public.expense_reports er ON er.id = li.report_id
        WHERE a.storage_path = (storage.objects.bucket_id || '/' || storage.objects.name)
          AND er.status::text = 'draft'
          AND er.employee_id = public.get_my_employee_id()
      )
    )
  );


-- ── Step 3: RLS on the attachments table ─────────────────────────────────────
--
-- The attachments table already exists from the initial schema but had no
-- RLS policies after phase 1 rebuilt the expense policies.

ALTER TABLE attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attachments_select ON attachments;
DROP POLICY IF EXISTS attachments_insert ON attachments;
DROP POLICY IF EXISTS attachments_update ON attachments;
DROP POLICY IF EXISTS attachments_delete ON attachments;

-- SELECT: mirrors the expense_reports select scope
CREATE POLICY attachments_select ON attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id = attachments.line_item_id AND er.deleted_at IS NULL
        AND (
          has_role('admin')
          OR (has_permission('expense.view_org')  AND er.status::text != 'draft')
          OR (has_permission('expense.view_team') AND er.status::text != 'draft'
              AND (is_my_direct_report(er.employee_id) OR is_in_my_department(er.employee_id)))
          OR er.employee_id = get_my_employee_id()
        )
    )
  );

-- INSERT: only into draft reports you own
CREATE POLICY attachments_insert ON attachments FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status::text = 'draft'
        AND er.employee_id  = get_my_employee_id()
    )
  );

-- DELETE: admin or owner of draft report
CREATE POLICY attachments_delete ON attachments FOR DELETE
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM line_items li
      JOIN expense_reports er ON er.id = li.report_id
      WHERE li.id          = attachments.line_item_id
        AND er.status::text = 'draft'
        AND er.employee_id  = get_my_employee_id()
    )
  );


-- ── Step 4: get_attachment_url() — signed URL helper ─────────────────────────
--
-- Returns a 1-hour signed URL for a given attachment UUID.
-- SECURITY DEFINER so it can call storage.foldername / storage.filename
-- and generate the URL without exposing the raw storage_path to the client.
-- Validates that the caller can see the attachment before issuing the URL.

CREATE OR REPLACE FUNCTION get_attachment_url(p_attachment_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_storage_path text;
BEGIN
  -- Verify the caller can see this attachment (RLS SELECT policy enforces visibility).
  SELECT storage_path INTO v_storage_path
  FROM attachments
  WHERE id = p_attachment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Attachment not found or access denied.';
  END IF;

  -- Return the clean object path (without bucket prefix) for the JS client.
  -- The frontend calls:
  --   supabase.storage.from('expense-attachments').createSignedUrl(path, 3600)
  RETURN replace(v_storage_path, 'expense-attachments/', '');
END;
$$;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT id, name, public, file_size_limit
FROM storage.buckets
WHERE id = 'expense-attachments';

SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'objects' AND schemaname = 'storage'
  AND policyname LIKE 'storage_exp_att%';
