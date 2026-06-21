-- Seed default app_name into theme_settings so get_theme_settings() returns it
INSERT INTO public.theme_settings (key, value, updated_at)
VALUES ('app_name', 'Prowess Workforce', now())
ON CONFLICT (key) DO NOTHING;
