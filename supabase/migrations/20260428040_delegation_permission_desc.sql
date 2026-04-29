-- =============================================================================
-- Delegation: permission description update + dept_head role grant
--
-- Two changes:
--
-- 1. Update workflow.approve description to reflect that the permission also
--    grants access to the self-service My Delegations feature.
--
-- 2. Grant workflow.approve to the dept_head role.
--    Dept heads are valid DEPT_HEAD approver targets in workflow templates.
--    Without workflow.approve they could receive tasks but could not set up
--    delegations when away — inconsistent with manager and finance who can.
--    This mirrors the existing grant pattern from 20260427030_workflow_phase1.
-- =============================================================================

-- ── 1. Update description ─────────────────────────────────────────────────────

UPDATE permissions
SET description =
  'Review and approve or reject workflow tasks assigned to you. '
  'Also grants access to self-service delegation — set up a temporary '
  'delegate to receive your approval tasks while you are away.'
WHERE code = 'workflow.approve';


-- ── 2. Grant workflow.approve to dept_head ────────────────────────────────────

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles       r
CROSS JOIN permissions p
WHERE  r.code = 'dept_head'
  AND  p.code = 'workflow.approve'
ON CONFLICT DO NOTHING;


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm updated description
SELECT code, description
FROM   permissions
WHERE  code = 'workflow.approve';

-- Confirm dept_head now has the permission
SELECT r.code AS role, p.code AS permission
FROM   role_permissions rp
JOIN   roles       r ON r.id = rp.role_id
JOIN   permissions p ON p.id = rp.permission_id
WHERE  p.code = 'workflow.approve'
ORDER  BY r.code;
