-- Bulletproof fix for theme_manager permission
-- Delete whatever exists (wrong code, right code — doesn't matter)
-- ON DELETE CASCADE on permission_set_items means any accidental grants are
-- also removed. Safe because the toggle was never clickable, so no real grants exist.

DELETE FROM public.permissions WHERE code LIKE 'theme_manager.%';

-- Re-insert with the correct code, linked to the theme_manager module
INSERT INTO public.permissions (code, name, description, module_id, action, sort_order)
SELECT
  'theme_manager.view',
  'Manage Theme',
  'Upload logos, favicon and update login page tagline.',
  m.id,
  'view',
  1
FROM public.modules m
WHERE m.code = 'theme_manager';
