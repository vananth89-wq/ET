-- =============================================================================
-- Migration 223: Register all workflow-eligible modules in module_codes
--
-- CONTEXT
-- ───────
-- module_codes is the FK anchor for workflow_assignments and workflow_instances.
-- WorkflowAssignments.tsx now queries this table directly (no hardcoded list),
-- so every module that should appear in the Workflow Assignments dropdown must
-- be registered here.
--
-- WHAT IS BEING ADDED
-- ────────────────────
-- Previously registered (do nothing on conflict):
--   expense_reports, time_off, employee_hire
--
-- Newly added:
--   Employee satellite sections (profile edits submitted by ESS users):
--     profile_personal, profile_contact, profile_employment,
--     profile_address, profile_passport, profile_identification,
--     profile_emergency_contact
--
--   Employee record (admin edits requiring approval):
--     employee_edit
--
--   Departments:
--     department_create, department_edit
--
--   Projects:
--     project_create, project_edit
--
--   Delegations:
--     delegations
--
--   Exchange Rates:
--     exchange_rate_update
--
-- NOTE ON edit_route
-- ──────────────────
-- edit_route is used by WorkflowReview to navigate the approver back to the
-- source form. Leave NULL for modules whose route is not yet implemented.
-- Update when the screen is built.
-- =============================================================================


INSERT INTO module_codes (code, label, description, edit_route) VALUES

  -- ── Employee satellite / profile sections ──────────────────────────────────
  ('profile_personal',
   'Profile — Personal Info',
   'Name, nationality, date of birth, marital status changes submitted by employee.',
   '/profile/personal'),

  ('profile_contact',
   'Profile — Contact Info',
   'Mobile, personal email, and emergency phone changes submitted by employee.',
   '/profile/contact'),

  ('profile_employment',
   'Profile — Employment Details',
   'Designation, department, work location, and reporting-line changes.',
   '/profile/employment'),

  ('profile_address',
   'Profile — Address',
   'Residential and permanent address changes submitted by employee.',
   '/profile/address'),

  ('profile_passport',
   'Profile — Passport & Visa',
   'Passport number, expiry, visa details changes submitted by employee.',
   '/profile/passport'),

  ('profile_identification',
   'Profile — Identification',
   'National ID, tax ID, and other government identifier changes.',
   '/profile/identification'),

  ('profile_emergency_contact',
   'Profile — Emergency Contact',
   'Emergency contact name, relationship, and phone number changes.',
   '/profile/emergency-contact'),

  -- ── Employee record (admin-initiated edits) ────────────────────────────────
  ('employee_edit',
   'Employee — Edit Details',
   'Admin edits to an active employee record requiring HR Head approval.',
   '/employees/'),     -- append employee UUID at runtime

  -- ── Departments ───────────────────────────────────────────────────────────
  ('department_create',
   'Department — Create',
   'New department creation requiring approval.',
   '/admin/departments/new'),

  ('department_edit',
   'Department — Edit',
   'Changes to department name, head, cost centre, or parent structure.',
   '/admin/departments/'),   -- append department id at runtime

  -- ── Projects ──────────────────────────────────────────────────────────────
  ('project_create',
   'Project — Create',
   'New project creation requiring approval.',
   '/admin/projects/new'),

  ('project_edit',
   'Project — Edit',
   'Project details, budget, or timeline changes requiring approval.',
   '/admin/projects/'),      -- append project id at runtime

  -- ── Delegations ───────────────────────────────────────────────────────────
  ('delegations',
   'Delegations',
   'Approval delegation requests — temporarily route approvals to a delegate.',
   '/admin/delegations'),

  -- ── Exchange Rates ────────────────────────────────────────────────────────
  ('exchange_rate_update',
   'Exchange Rates — Update',
   'Currency exchange rate updates requiring Finance Head approval.',
   '/admin/exchange-rates')

ON CONFLICT (code) DO UPDATE
  SET label       = EXCLUDED.label,
      description = EXCLUDED.description,
      edit_route  = COALESCE(module_codes.edit_route, EXCLUDED.edit_route);
-- ↑ COALESCE: only backfill edit_route if currently NULL — don't overwrite
--   a route that was already set correctly in a prior migration.


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT code, label, edit_route
FROM   module_codes
ORDER  BY label;

-- =============================================================================
-- END OF MIGRATION 223
-- =============================================================================
