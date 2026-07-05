-- Migration 669 — Allow any authenticated user to read hr-attachments
-- ─────────────────────────────────────────────────────────────────────────────
-- Approvers (e.g. HR Head) could not view/download attachments uploaded by
-- others (e.g. Vijey) in the workflow approver inbox because the storage
-- SELECT policy was restricted to the file owner.
-- Fix: allow any authenticated user to SELECT objects in hr-attachments.
-- This enables createSignedUrl() to succeed for any authenticated user.

-- Drop any existing restrictive SELECT policy on hr-attachments
DROP POLICY IF EXISTS "Users can read their own uploads"     ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can read uploads" ON storage.objects;
DROP POLICY IF EXISTS "hr_attachments_owner_read"            ON storage.objects;
DROP POLICY IF EXISTS "hr_attachments_read"                  ON storage.objects;

-- Allow any authenticated user to read (SELECT) from hr-attachments
-- This is needed for createSignedUrl() to succeed in the approver inbox.
CREATE POLICY "hr_attachments_read"
ON storage.objects
FOR SELECT
TO authenticated
USING (bucket_id = 'hr-attachments');
