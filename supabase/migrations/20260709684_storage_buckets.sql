-- ── Ensure storage buckets exist ────────────────────────────────────────────
--
-- Storage buckets are managed by the Supabase Storage service via
-- `storage.buckets`. They don't come with a schema-only dump — Prod and Dev
-- have them from initial dashboard setup, but a fresh Local (Docker) or a
-- rebuilt env starts with zero buckets. This migration is idempotent
-- (`ON CONFLICT DO NOTHING`) so it's safe to re-run.
--
-- Buckets:
--   - avatars              : public — user profile pictures
--   - expense-attachments  : private (RLS-protected) — expense receipts
--   - hr-attachments       : private (RLS-protected) — bank docs, ID proofs,
--                            dependent docs, education certificates, etc.
--
-- Existing RLS policies on storage.objects (added in earlier migrations) will
-- apply. If those policies are missing on a fresh env, buckets will still
-- exist but uploads will fail with 401 — check for `storage.objects` policies
-- separately.

INSERT INTO storage.buckets (id, name, public)
VALUES
  ('avatars',              'avatars',              true),
  ('expense-attachments',  'expense-attachments',  false),
  ('hr-attachments',       'hr-attachments',       false)
ON CONFLICT (id) DO NOTHING;
