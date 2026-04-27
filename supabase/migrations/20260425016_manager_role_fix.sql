-- =============================================================================
-- Fix Manager Role Classification
--
-- Background:
--   migration 007 (drop_mss) moved manager from system-synced to manually
--   assigned — sync_system_roles() no longer handles the manager role.
--   However the role was still seeded as role_type='system', editable=false,
--   which hides it from the editable panel in Role Assignments.
--
-- Changes:
--   1. Ensure manager role exists and is active
--   2. Set role_type = 'custom', editable = true (manually assigned)
--   3. Sort order: slot between dept_head and ess so the list reads naturally
--      Protected → System (dept_head, ess) → Custom (admin-assigned: manager, finance, hr)
-- =============================================================================


-- ── Upsert the manager role with correct classification ───────────────────────

INSERT INTO roles (code, name, description, role_type, is_system, active, editable, sort_order)
VALUES (
  'manager',
  'Manager',
  'Team management — expense approvals and direct report visibility. Assigned manually by Admin.',
  'custom',   -- manually assigned, not system-synced
  false,      -- is_system = false (sync_system_roles no longer manages this role)
  true,       -- active
  true,       -- editable in Role Assignments UI
  10          -- sorts after system roles (dept_head=5, ess=7)
)
ON CONFLICT (code) DO UPDATE
  SET role_type   = 'custom',
      is_system   = false,
      active      = true,
      editable    = true,
      name        = EXCLUDED.name,
      description = EXCLUDED.description,
      sort_order  = EXCLUDED.sort_order;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT code, name, role_type, is_system, active, editable, sort_order
FROM   roles
WHERE  code IN ('manager', 'mss', 'ess', 'dept_head', 'finance', 'hr', 'admin')
ORDER  BY sort_order;
