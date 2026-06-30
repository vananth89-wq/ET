-- Add termination section to profile_sections theme setting.
-- The original seed (20260618570) used ON CONFLICT DO NOTHING so the row exists;
-- this migration appends the termination entry to the JSON array.

UPDATE public.theme_settings
SET value = (
  SELECT jsonb_pretty(
    COALESCE(value::jsonb, '[]'::jsonb) ||
    '[{"id":"termination","label":"Termination","icon":"fa-person-walking-arrow-right","visible":true,"order":12}]'::jsonb
  )
  FROM public.theme_settings
  WHERE key = 'profile_sections'
)
WHERE key = 'profile_sections'
  AND NOT (value::jsonb @> '[{"id":"termination"}]'::jsonb);
