-- ── Theme RPCs ──────────────────────────────────────────────────────────────

-- get_theme_settings: public, no auth required (login page needs it pre-login)
CREATE OR REPLACE FUNCTION public.get_theme_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_object_agg(key, value)
  FROM public.theme_settings;
$$;

GRANT EXECUTE ON FUNCTION public.get_theme_settings() TO anon, authenticated;

-- upsert_theme_setting: requires theme_manager.view permission
CREATE OR REPLACE FUNCTION public.upsert_theme_setting(
  p_key   TEXT,
  p_value TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('theme_manager', 'view', NULL) THEN
    RAISE EXCEPTION 'Permission denied: theme_manager.view required';
  END IF;

  INSERT INTO public.theme_settings (key, value, updated_at, updated_by)
  VALUES (p_key, p_value, now(), auth.uid())
  ON CONFLICT (key) DO UPDATE
    SET value      = EXCLUDED.value,
        updated_at = now(),
        updated_by = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_theme_setting(TEXT, TEXT) TO authenticated;
