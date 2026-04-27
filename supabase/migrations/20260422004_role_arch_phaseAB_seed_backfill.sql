-- =============================================================================
-- Role Architecture — Phase A+B: Seed roles master data + backfill user_roles
--
-- Phase A: Ensure all legacy enum values have rows in roles table.
-- Phase B: Backfill user_roles from profile_roles using enum→code mapping.
--
-- Safe to re-run (all inserts are ON CONFLICT DO NOTHING).
-- =============================================================================


-- ── Phase A: Roles master data ────────────────────────────────────────────────
--
-- Enum → roles.code mapping decisions:
--
--   admin     → admin       (identical, protected, system)
--   finance   → finance     (identical, system)
--   hr        → hr          (identical, system)
--   manager   → manager     (pure management — approvals, team visibility)
--   dept_head → dept_head   (department head — maps to manager DB access)
--   mss       → mss         (Manager Self Service — portal access)
--   employee  → ess         (Employee Self Service — matches UI naming)
--
-- Note: manager + dept_head + mss all grant manager-level DB access
-- but are separate roles for UI clarity and future permission differentiation.

INSERT INTO roles (code, name, description, role_type, is_system, active, editable, sort_order)
VALUES
  ('admin',     'Administrator',       'Full system access. Protected — last admin cannot be removed.',
   'protected', true,  true, false, 1),
  ('finance',   'Finance',             'Access to submitted expense reports, currencies and rates.',
   'system',    true,  true, false, 2),
  ('hr',        'HR',                  'Human resources access to employee data.',
   'system',    true,  true, false, 3),
  ('manager',   'Manager',             'Team management — approvals, direct report visibility.',
   'system',    true,  true, false, 4),
  ('dept_head', 'Department Head',     'Department-level management access.',
   'system',    true,  true, false, 5),
  ('mss',       'Manager Self Service','Self-service portal access for managers.',
   'system',    true,  true, false, 6),
  ('ess',       'Employee Self Service','Self-service portal access for employees.',
   'system',    true,  true, false, 7)
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    role_type   = EXCLUDED.role_type,
    is_system   = EXCLUDED.is_system,
    sort_order  = EXCLUDED.sort_order,
    editable    = EXCLUDED.editable;
    -- Note: active left unchanged to avoid accidentally re-enabling a disabled role


-- ── Phase B: Backfill user_roles from profile_roles ──────────────────────────
--
-- Maps legacy enum values to roles.code and inserts into user_roles.
-- assignment_source = 'system' for system-managed roles, 'manual' for admin.
-- ON CONFLICT DO NOTHING — safe to re-run.

INSERT INTO user_roles (profile_id, role_id, granted_by, is_active, assignment_source, granted_at)
SELECT
  pr.profile_id,
  r.id,
  pr.assigned_by,
  true,
  CASE WHEN r.is_system THEN 'system' ELSE 'manual' END,
  pr.created_at
FROM profile_roles pr
JOIN roles r ON r.code = CASE pr.role::text
  WHEN 'admin'     THEN 'admin'
  WHEN 'finance'   THEN 'finance'
  WHEN 'hr'        THEN 'hr'
  WHEN 'manager'   THEN 'manager'
  WHEN 'dept_head' THEN 'dept_head'
  WHEN 'mss'       THEN 'mss'
  WHEN 'employee'  THEN 'ess'
  ELSE NULL
END
WHERE r.id IS NOT NULL
ON CONFLICT (profile_id, role_id) DO NOTHING;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT
  e.name                          AS employee,
  pr.role::text                   AS legacy_enum,
  r.code                          AS mapped_code,
  ur.id IS NOT NULL               AS backfilled
FROM profile_roles pr
JOIN profiles p ON p.id = pr.profile_id
LEFT JOIN employees e ON e.id = p.employee_id
LEFT JOIN roles r ON r.code = CASE pr.role::text
  WHEN 'admin'    THEN 'admin'
  WHEN 'finance'  THEN 'finance'
  WHEN 'hr'       THEN 'hr'
  WHEN 'manager'  THEN 'manager'
  WHEN 'dept_head'THEN 'dept_head'
  WHEN 'mss'      THEN 'mss'
  WHEN 'employee' THEN 'ess'
  ELSE NULL
END
LEFT JOIN user_roles ur
  ON  ur.profile_id = pr.profile_id
  AND ur.role_id    = r.id
ORDER BY e.name, pr.role::text;
