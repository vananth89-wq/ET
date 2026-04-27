-- =============================================================================
-- Employee Permission Set
--
-- Adds 20 granular employee permissions across 4 groups:
--
--   Group 1 — Admin-level (5):
--     employee.create            Add new employees
--     employee.edit              Edit any employee's core profile
--     employee.delete            Soft-delete employees
--     employee.view_directory    Basic directory + org lookups (all roles)
--     employee.view_orgchart_admin  Full org chart with mgmt metadata
--
--   Group 2 — View Own Profile (7):
--     employee.view_own_personal   Personal portlet (nationality, marital status, photo)
--     employee.view_own_contact    Contact portlet (mobile, personal email, country code)
--     employee.view_own_employment Employment portlet (designation, dept, manager, dates…)
--     employee.view_own_address    Address portlet
--     employee.view_own_passport   Passport portlet
--     employee.view_own_identity   Identity / ID Documents portlet
--     employee.view_own_emergency  Emergency contacts portlet
--
--   Group 3 — Edit Own Profile (7):
--     employee.edit_own_personal   (same portlets as above, write access)
--     employee.edit_own_contact
--     employee.edit_own_employment   ← Admin-only by default
--     employee.edit_own_address
--     employee.edit_own_passport
--     employee.edit_own_identity
--     employee.edit_own_emergency
--
--   Group 4 — Employee Org Chart (1):
--     employee.view_orgchart       Standard org chart view for all staff
--
-- Default role matrix:
--   • view_own_* (7)                    → ALL roles
--   • edit_own_* (6, excl. employment)  → ALL roles
--   • edit_own_employment               → admin only
--   • view_directory                    → ALL roles
--   • view_orgchart                     → ALL roles
--   • view_orgchart_admin               → admin, hr, manager, dept_head
--   • create, edit                      → admin, hr
--   • delete                            → admin only
--
-- Idempotent: ON CONFLICT DO NOTHING / DO UPDATE.
-- Does NOT touch expense.* or other module permissions.
-- =============================================================================


-- ── Part 1: Register permissions ─────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT p.code, p.name, p.description, m.id, p.sort_order
FROM (VALUES
  -- ── Group 1: Admin-level ────────────────────────────────────────────────
  ('employee.create',               'Create Employee',
    'Add a new employee record to the system.',
    10),
  ('employee.edit',                 'Edit Employee',
    'Edit any employee''s core profile data (admin / HR use).',
    20),
  ('employee.delete',               'Delete Employee',
    'Soft-delete (deactivate) an employee record.',
    30),
  ('employee.view_directory',       'View Employee Directory',
    'Search and browse the employee directory; required for org-chart dropdowns.',
    40),
  ('employee.view_orgchart_admin',  'View Org Chart (Admin)',
    'Full org chart with reporting lines, head counts and management metadata.',
    50),

  -- ── Groups 2 + 3: View + Edit paired per portlet ──────────────────────
  -- Each portlet: view first (N0), edit second (N5) — sorted together in UI.

  -- Personal
  ('employee.view_own_personal',    'View Own Personal Info',
    'View own Personal portlet: nationality, marital status, photo.',
    60),
  ('employee.edit_own_personal',    'Edit Own Personal Info',
    'Edit own Personal portlet: nationality, marital status, photo.',
    65),

  -- Contact
  ('employee.view_own_contact',     'View Own Contact Info',
    'View own Contact portlet: mobile, personal email, country code.',
    70),
  ('employee.edit_own_contact',     'Edit Own Contact Info',
    'Edit own Contact portlet: mobile, personal email, country code.',
    75),

  -- Employment
  ('employee.view_own_employment',  'View Own Employment Info',
    'View own Employment portlet: designation, department, manager, hire date, end date, work location, currency.',
    80),
  ('employee.edit_own_employment',  'Edit Own Employment Info',
    'Edit own Employment portlet. Admin-only by default — employment terms are set by HR.',
    85),

  -- Address
  ('employee.view_own_address',     'View Own Address',
    'View own Address portlet: residential and mailing address.',
    90),
  ('employee.edit_own_address',     'Edit Own Address',
    'Edit own Address portlet: residential and mailing address.',
    95),

  -- Passport
  ('employee.view_own_passport',    'View Own Passport',
    'View own Passport portlet: passport number, country, dates, visa details.',
    100),
  ('employee.edit_own_passport',    'Edit Own Passport',
    'Edit own Passport portlet: passport number, country, dates, visa details.',
    105),

  -- Identity Documents
  ('employee.view_own_identity',    'View Own Identity Documents',
    'View own Identity portlet: ID type, number, issuing country, dates.',
    110),
  ('employee.edit_own_identity',    'Edit Own Identity Documents',
    'Edit own Identity portlet: ID type, number, issuing country, dates.',
    115),

  -- Emergency Contacts
  ('employee.view_own_emergency',   'View Own Emergency Contacts',
    'View own Emergency Contacts portlet: contact name, relationship, phone, email.',
    120),
  ('employee.edit_own_emergency',   'Edit Own Emergency Contacts',
    'Edit own Emergency Contacts portlet: contact name, relationship, phone, email.',
    125),

  -- ── Group 4: Employee Org Chart ─────────────────────────────────────────
  ('employee.view_orgchart',        'View Org Chart',
    'Standard org chart view showing reporting structure and team hierarchy.',
    200)

) AS p(code, name, description, sort_order)
JOIN modules m ON m.code = 'employee'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order,
      module_id   = EXCLUDED.module_id;


-- ── Part 2: Default role_permissions matrix ──────────────────────────────────
--
-- Safe to run multiple times — ON CONFLICT DO NOTHING.
-- Admin can override any of these through the Role Management UI.

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES

  -- ── employee.create → admin, hr ───────────────────────────────────────────
  ('admin',     'employee.create'),
  ('hr',        'employee.create'),

  -- ── employee.edit → admin, hr ─────────────────────────────────────────────
  ('admin',     'employee.edit'),
  ('hr',        'employee.edit'),

  -- ── employee.delete → admin only ──────────────────────────────────────────
  ('admin',     'employee.delete'),

  -- ── employee.view_directory → ALL roles ───────────────────────────────────
  ('admin',     'employee.view_directory'),
  ('finance',   'employee.view_directory'),
  ('hr',        'employee.view_directory'),
  ('manager',   'employee.view_directory'),
  ('dept_head', 'employee.view_directory'),
  ('ess',       'employee.view_directory'),

  -- ── employee.view_orgchart_admin → admin, hr, manager, dept_head ──────────
  ('admin',     'employee.view_orgchart_admin'),
  ('hr',        'employee.view_orgchart_admin'),
  ('manager',   'employee.view_orgchart_admin'),
  ('dept_head', 'employee.view_orgchart_admin'),

  -- ── view_own_* → ALL roles ────────────────────────────────────────────────
  ('admin',     'employee.view_own_personal'),
  ('finance',   'employee.view_own_personal'),
  ('hr',        'employee.view_own_personal'),
  ('manager',   'employee.view_own_personal'),
  ('dept_head', 'employee.view_own_personal'),
  ('ess',       'employee.view_own_personal'),

  ('admin',     'employee.view_own_contact'),
  ('finance',   'employee.view_own_contact'),
  ('hr',        'employee.view_own_contact'),
  ('manager',   'employee.view_own_contact'),
  ('dept_head', 'employee.view_own_contact'),
  ('ess',       'employee.view_own_contact'),

  ('admin',     'employee.view_own_employment'),
  ('finance',   'employee.view_own_employment'),
  ('hr',        'employee.view_own_employment'),
  ('manager',   'employee.view_own_employment'),
  ('dept_head', 'employee.view_own_employment'),
  ('ess',       'employee.view_own_employment'),

  ('admin',     'employee.view_own_address'),
  ('finance',   'employee.view_own_address'),
  ('hr',        'employee.view_own_address'),
  ('manager',   'employee.view_own_address'),
  ('dept_head', 'employee.view_own_address'),
  ('ess',       'employee.view_own_address'),

  ('admin',     'employee.view_own_passport'),
  ('finance',   'employee.view_own_passport'),
  ('hr',        'employee.view_own_passport'),
  ('manager',   'employee.view_own_passport'),
  ('dept_head', 'employee.view_own_passport'),
  ('ess',       'employee.view_own_passport'),

  ('admin',     'employee.view_own_identity'),
  ('finance',   'employee.view_own_identity'),
  ('hr',        'employee.view_own_identity'),
  ('manager',   'employee.view_own_identity'),
  ('dept_head', 'employee.view_own_identity'),
  ('ess',       'employee.view_own_identity'),

  ('admin',     'employee.view_own_emergency'),
  ('finance',   'employee.view_own_emergency'),
  ('hr',        'employee.view_own_emergency'),
  ('manager',   'employee.view_own_emergency'),
  ('dept_head', 'employee.view_own_emergency'),
  ('ess',       'employee.view_own_emergency'),

  -- ── edit_own_* (except employment) → ALL roles ────────────────────────────
  ('admin',     'employee.edit_own_personal'),
  ('finance',   'employee.edit_own_personal'),
  ('hr',        'employee.edit_own_personal'),
  ('manager',   'employee.edit_own_personal'),
  ('dept_head', 'employee.edit_own_personal'),
  ('ess',       'employee.edit_own_personal'),

  ('admin',     'employee.edit_own_contact'),
  ('finance',   'employee.edit_own_contact'),
  ('hr',        'employee.edit_own_contact'),
  ('manager',   'employee.edit_own_contact'),
  ('dept_head', 'employee.edit_own_contact'),
  ('ess',       'employee.edit_own_contact'),

  -- ── edit_own_employment → admin ONLY ──────────────────────────────────────
  ('admin',     'employee.edit_own_employment'),

  ('admin',     'employee.edit_own_address'),
  ('finance',   'employee.edit_own_address'),
  ('hr',        'employee.edit_own_address'),
  ('manager',   'employee.edit_own_address'),
  ('dept_head', 'employee.edit_own_address'),
  ('ess',       'employee.edit_own_address'),

  ('admin',     'employee.edit_own_passport'),
  ('finance',   'employee.edit_own_passport'),
  ('hr',        'employee.edit_own_passport'),
  ('manager',   'employee.edit_own_passport'),
  ('dept_head', 'employee.edit_own_passport'),
  ('ess',       'employee.edit_own_passport'),

  ('admin',     'employee.edit_own_identity'),
  ('finance',   'employee.edit_own_identity'),
  ('hr',        'employee.edit_own_identity'),
  ('manager',   'employee.edit_own_identity'),
  ('dept_head', 'employee.edit_own_identity'),
  ('ess',       'employee.edit_own_identity'),

  ('admin',     'employee.edit_own_emergency'),
  ('finance',   'employee.edit_own_emergency'),
  ('hr',        'employee.edit_own_emergency'),
  ('manager',   'employee.edit_own_emergency'),
  ('dept_head', 'employee.edit_own_emergency'),
  ('ess',       'employee.edit_own_emergency'),

  -- ── employee.view_orgchart → ALL roles ────────────────────────────────────
  ('admin',     'employee.view_orgchart'),
  ('finance',   'employee.view_orgchart'),
  ('hr',        'employee.view_orgchart'),
  ('manager',   'employee.view_orgchart'),
  ('dept_head', 'employee.view_orgchart'),
  ('ess',       'employee.view_orgchart')

) AS rp(role_code, perm_code)
JOIN roles r ON r.code = rp.role_code AND r.active = true
JOIN permissions p ON p.code = rp.perm_code
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT
  p.code,
  p.name,
  p.sort_order,
  COALESCE(array_agg(r.code ORDER BY r.sort_order) FILTER (WHERE r.id IS NOT NULL), '{}') AS assigned_roles
FROM permissions p
LEFT JOIN role_permissions rp ON rp.permission_id = p.id
LEFT JOIN roles r ON r.id = rp.role_id
WHERE p.code LIKE 'employee.%'
  AND p.code NOT IN ('employee.view', 'employee.view_all', 'employee.edit_sensitive')  -- legacy
GROUP BY p.code, p.name, p.sort_order
ORDER BY p.sort_order, p.code;
