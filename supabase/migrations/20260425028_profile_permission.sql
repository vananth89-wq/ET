-- =============================================================================
-- Profile permissions — self-service own-profile access
--
-- Every authenticated employee needs to view and edit their own profile page.
-- These two permissions gate the /profile route so the guard system is
-- consistent (no unguarded routes) without blocking any legitimate user.
--
-- New permissions (employee module):
--   profile.view_own   View your own profile page
--   profile.edit_own   Edit your own profile page settings (e.g. avatar, preferences)
--
-- All 7 active roles receive both permissions — every user must be able to
-- access their own profile regardless of their admin capabilities.
-- =============================================================================

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('profile.view_own',
   'View Own Profile',
   'View your own employee profile page, including personal details, contact info and employment summary.',
   5),
  ('profile.edit_own',
   'Edit Own Profile',
   'Update your own profile settings such as avatar and notification preferences.',
   6)
) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- Grant to all active roles — every user must reach their own profile
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('admin',     'profile.view_own'),
  ('finance',   'profile.view_own'),
  ('hr',        'profile.view_own'),
  ('manager',   'profile.view_own'),
  ('dept_head', 'profile.view_own'),
  ('ess',       'profile.view_own'),
  ('admin',     'profile.edit_own'),
  ('finance',   'profile.edit_own'),
  ('hr',        'profile.edit_own'),
  ('manager',   'profile.edit_own'),
  ('dept_head', 'profile.edit_own'),
  ('ess',       'profile.edit_own')
) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT (role_id, permission_id) DO NOTHING;
