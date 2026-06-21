-- Fix theme_manager permission code (was incorrectly inserted as 'theme_manager.manage')
UPDATE public.permissions
SET code   = 'theme_manager.view',
    action = 'view'
WHERE code = 'theme_manager.manage';

-- Also ensure the correct row exists (in case the above finds nothing)
INSERT INTO public.permissions (code, name, description, module_id, action, sort_order)
SELECT
  'theme_manager.view',
  'Manage Theme',
  'Upload logos, favicon and update login page tagline.',
  m.id,
  'view',
  1
FROM public.modules m
WHERE m.code = 'theme_manager'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      action      = EXCLUDED.action,
      module_id   = EXCLUDED.module_id;
