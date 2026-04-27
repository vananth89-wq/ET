-- =============================================================================
-- admin.access — dedicated Admin portal gate
--
-- A single permission that controls whether the Admin section is visible in
-- the navigation. Completely decoupled from what the user can *do* inside
-- admin — individual pages still require their own permissions.
--
-- Also seeds security.assign_access which was referenced in descriptions
-- but never formally registered.
--
-- Role matrix:
--   admin.access         → admin, finance, hr, manager, dept_head  (never mss/ess)
--   security.assign_access → admin  (HR can request, admin executes)
--
-- Run order: after 20260425026 (permission descriptions).
-- =============================================================================


-- ── Part 1: Register permissions ─────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  ('admin.access',
   'Access Admin Panel',
   'Grants access to the Admin section of the application. Without this permission the Admin link is hidden and all admin pages are inaccessible, regardless of any other permissions the user holds.',
   5),
  ('security.assign_access',
   'Assign User Roles',
   'Assign or change the role of a user — for example promoting a new joiner from Employee (ESS) to Manager.',
   10)
) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'security'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- ── Part 2: Default role_permissions matrix ──────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  -- admin.access → all admin-tier roles (not mss / ess)
  ('admin',     'admin.access'),
  ('finance',   'admin.access'),
  ('hr',        'admin.access'),
  ('manager',   'admin.access'),
  ('dept_head', 'admin.access'),

  -- security.assign_access → admin only
  ('admin', 'security.assign_access')

) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT
  p.code,
  p.name,
  COALESCE(
    array_agg(r.code ORDER BY r.sort_order) FILTER (WHERE r.id IS NOT NULL),
    '{}'
  ) AS assigned_roles
FROM permissions p
LEFT JOIN role_permissions rp ON rp.permission_id = p.id
LEFT JOIN roles r ON r.id = rp.role_id
WHERE p.code IN ('admin.access', 'security.assign_access')
GROUP BY p.code, p.name
ORDER BY p.code;
