-- =============================================================================
-- Migration 091: RBP Phase 4 — Granular Security / Workflow / Jobs permissions
--
-- WHAT THIS DOES
-- ══════════════
-- The Permission Matrix UI shows individual toggle rows for each Security,
-- Workflow, and Jobs sub-feature.  Until now these three groups shared a
-- single module code each (security_admin, workflow_admin, jobs_admin), which
-- only allowed a single ON/OFF for the entire group.
--
-- This migration adds one module + one 'view' permission per sub-feature so
-- that each toggle row persists its own role_permissions row independently.
--
-- Module code conventions
-- ───────────────────────
--   sec_*   → Security sub-features
--   wf_*    → Workflow sub-features
--   jobs_*  → Jobs sub-features
--
-- Existing security_admin / workflow_admin / jobs_admin modules are kept
-- intact (used by the legacy has_permission() system and RoleManagement UI).
-- The new granular modules are ONLY used by the Permission Matrix.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New module codes
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES
  -- ── Security sub-features ─────────────────────────────────────────────────
  ('sec_admin_access',       'Admin Access',              true, 300),
  ('sec_role_assignments',   'Role Assignments',          true, 301),
  ('sec_target_groups',      'Target Groups',             true, 302),
  ('sec_permission_catalog', 'Permission Catalog',        true, 303),
  ('sec_rbp_troubleshoot',   'RBP Troubleshoot',          true, 304),

  -- ── Workflow sub-features ─────────────────────────────────────────────────
  ('wf_manage',              'Manage Workflows',          true, 400),
  ('wf_templates',           'Workflow Templates',        true, 401),
  ('wf_delegations',         'Delegations',               true, 402),
  ('wf_assignments',         'WF Assignments',            true, 403),
  ('wf_analytics',           'Workflow Analytics',        true, 404),
  ('wf_notifications',       'Workflow Notifications',    true, 405),
  ('wf_performance',         'Workflow Performance',      true, 406),

  -- ── Jobs sub-features ─────────────────────────────────────────────────────
  ('jobs_manage',            'Manage Jobs',               true, 500)

ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. View permissions for each new module
--    code = '<module_code>.view', action = 'view'
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  m.code || '.view'        AS code,
  'Access ' || m.name      AS name,
  'Grants access to the ' || m.name || ' feature' AS description,
  m.id                     AS module_id,
  'view'                   AS action
FROM modules m
WHERE m.code IN (
  'sec_admin_access',
  'sec_role_assignments',
  'sec_target_groups',
  'sec_permission_catalog',
  'sec_rbp_troubleshoot',
  'wf_manage',
  'wf_templates',
  'wf_delegations',
  'wf_assignments',
  'wf_analytics',
  'wf_notifications',
  'wf_performance',
  'jobs_manage'
)
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'new granular permissions' AS check, count(*) AS rows
FROM permissions
WHERE code IN (
  'sec_admin_access.view',
  'sec_role_assignments.view',
  'sec_target_groups.view',
  'sec_permission_catalog.view',
  'sec_rbp_troubleshoot.view',
  'wf_manage.view',
  'wf_templates.view',
  'wf_delegations.view',
  'wf_assignments.view',
  'wf_analytics.view',
  'wf_notifications.view',
  'wf_performance.view',
  'jobs_manage.view'
);
-- =============================================================================
-- END OF MIGRATION 20260501091_rbp_granular_toggle_permissions.sql
-- =============================================================================
