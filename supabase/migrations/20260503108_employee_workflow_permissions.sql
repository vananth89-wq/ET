-- =============================================================================
-- Migration 108: Employee Workflow Permissions
--
-- Adds two new employee-facing workflow feature permissions:
--   wf_my_requests.view  — access the "My Requests" screen (submitter view)
--   wf_inbox.view        — access the Approver Inbox (approver view)
--
-- These replace the old codes:
--   workflow.submit  → wf_my_requests.view
--   workflow.approve → wf_inbox.view
--
-- No target group required for either — both are inherently self-scoped:
--   wf_my_requests: always shows YOUR OWN submissions
--   wf_inbox:       always shows tasks ASSIGNED TO YOU by the workflow engine
--
-- Permission set assignment is NOT done here — admin configures that through
-- the Permission Matrix UI. This migration only registers the catalog entries.
-- =============================================================================

-- ── Step 1: Insert new modules ────────────────────────────────────────────────

INSERT INTO modules (code, name, active, sort_order)
VALUES
  ('wf_my_requests', 'My Requests',    true, 200),
  ('wf_inbox',       'Approver Inbox', true, 201)
ON CONFLICT (code) DO NOTHING;

-- ── Step 2: Insert permissions (view action only — these are feature flags) ──

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_my_requests.view',
  'View My Requests',
  'Access the My Requests screen — see own workflow submissions, track status, respond to clarifications',
  m.id,
  'view'
FROM modules m WHERE m.code = 'wf_my_requests'
ON CONFLICT (code) DO NOTHING;

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_inbox.view',
  'View Approver Inbox',
  'Access the Approver Inbox — see and action workflow tasks assigned to this user.',
  m.id,
  'view'
FROM modules m WHERE m.code = 'wf_inbox'
ON CONFLICT (code) DO NOTHING;

-- ── Verification ──────────────────────────────────────────────────────────────
-- Run after applying to confirm permissions are registered in the catalog:
--
-- SELECT code, name FROM permissions WHERE code IN ('wf_my_requests.view', 'wf_inbox.view');
--
-- Expected:
--   wf_my_requests.view | View My Requests
--   wf_inbox.view       | View Approver Inbox
--
-- Assignment to permission sets is done through the Permission Matrix UI by the admin.
-- No seeding here — configuration is not migration responsibility.
