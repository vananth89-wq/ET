-- ── Theme Manager: settings table + module + permission ─────────────────────

-- 1. Settings table
CREATE TABLE IF NOT EXISTS public.theme_settings (
  key         TEXT PRIMARY KEY,
  value       TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by  UUID REFERENCES auth.users(id)
);

ALTER TABLE public.theme_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "theme_settings_read" ON public.theme_settings
  FOR SELECT TO authenticated USING (true);

-- 2. Seed default values (idempotent)
INSERT INTO public.theme_settings (key, value) VALUES
  ('login_brand_logo',  NULL),
  ('login_card_logo',   NULL),
  ('nav_logo',          NULL),
  ('favicon',           NULL),
  ('login_tagline',     'Empowering people. Simplifying work.')
ON CONFLICT (key) DO NOTHING;

-- 3. Module + permission
INSERT INTO modules (code, name, active, sort_order)
VALUES ('theme_manager', 'Theme Manager', true, 999)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;

INSERT INTO permissions (code, name, description, module_id, action, sort_order)
SELECT
  'theme_manager.view',
  'Manage Theme',
  'Upload logos, favicon and update login page tagline.',
  m.id,
  'view',
  1
FROM modules m WHERE m.code = 'theme_manager'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      action      = EXCLUDED.action,
      module_id   = EXCLUDED.module_id;

-- 4. Storage bucket (public, for logos/favicons)
INSERT INTO storage.buckets (id, name, public)
VALUES ('theme', 'theme', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'theme_bucket_read' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "theme_bucket_read" ON storage.objects
      FOR SELECT USING (bucket_id = 'theme');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'theme_bucket_write' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "theme_bucket_write" ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'theme');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'theme_bucket_update' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "theme_bucket_update" ON storage.objects
      FOR UPDATE TO authenticated
      USING (bucket_id = 'theme');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'theme_bucket_delete' AND tablename = 'objects'
  ) THEN
    CREATE POLICY "theme_bucket_delete" ON storage.objects
      FOR DELETE TO authenticated
      USING (bucket_id = 'theme');
  END IF;
END $$;
