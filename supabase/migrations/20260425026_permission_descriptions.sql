-- =============================================================================
-- Meaningful plain-language descriptions for all permissions
--
-- Replaces terse or missing descriptions with sentences that make sense to a
-- non-technical admin reading the Role Management grid.
-- =============================================================================

UPDATE permissions SET description = d.description
FROM (VALUES

  -- ── Expense ────────────────────────────────────────────────────────────────
  ('expense.submit',
   'Submit a new expense report for approval.'),
  ('expense.view_own',
   'View your own submitted expense reports and their current status.'),
  ('expense.view_direct_reports',
   'View expense reports submitted by employees who report directly to you.'),
  ('expense.view_all',
   'View all expense reports across the organisation, regardless of who submitted them.'),
  ('expense.approve',
   'Approve or reject expense reports submitted by your direct reports.'),
  ('expense.finance_approve',
   'Give final finance approval to expense reports that have already been manager-approved.'),
  ('expense.delete',
   'Delete a draft or rejected expense report permanently.'),

  -- ── Employee — admin actions ────────────────────────────────────────────────
  ('employee.create',
   'Add a new employee record to the system.'),
  ('employee.edit',
   'Edit any employee''s core details — name, designation, department, manager and employment status.'),
  ('employee.delete',
   'Deactivate (soft-delete) an employee record so it no longer appears in active lists.'),
  ('employee.view_directory',
   'Browse the employee directory: names, employee IDs, designations, departments and business emails.'),
  ('employee.view_orgchart_admin',
   'View the full admin org chart including reporting lines, department heads, team sizes and employee status.'),

  -- ── Employee — own record (personal portlets) ───────────────────────────────
  ('employee.view_own_personal',
   'View your own personal details: full name, date of birth, gender, nationality and marital status.'),
  ('employee.edit_own_personal',
   'Update your own personal details such as date of birth, gender, nationality and marital status.'),
  ('employee.view_own_contact',
   'View your own contact information: personal email, phone number and address.'),
  ('employee.edit_own_contact',
   'Update your own contact information: personal email, phone number and address.'),
  ('employee.view_own_employment',
   'View your own employment details: designation, department, manager, hire date and salary grade.'),
  ('employee.edit_own_employment',
   'Update your own employment details. Reserved for admin — employees cannot change their own grade or designation.'),
  ('employee.view_own_address',
   'View your own registered home and mailing addresses.'),
  ('employee.edit_own_address',
   'Update your own registered home and mailing addresses.'),
  ('employee.view_own_passport',
   'View your own passport details: number, issuing country and expiry date.'),
  ('employee.edit_own_passport',
   'Update your own passport details: number, issuing country and expiry date.'),
  ('employee.view_own_identity',
   'View your own national identity documents (e.g. Aadhaar, Emirates ID, NRIC).'),
  ('employee.edit_own_identity',
   'Update your own national identity document numbers and expiry dates.'),
  ('employee.view_own_emergency',
   'View your own emergency contact names, relationships and phone numbers.'),
  ('employee.edit_own_emergency',
   'Add or update your own emergency contacts.'),
  ('employee.view_orgchart',
   'View the organisation chart showing your team, your manager and peer reporting lines.'),

  -- ── Organisation / Departments ─────────────────────────────────────────────
  ('department.view',
   'Browse the department list and use department dropdowns throughout the app (e.g. when filtering employees or submitting expenses).'),
  ('department.create',
   'Add a new department to the organisation structure.'),
  ('department.edit',
   'Edit a department''s name, description or parent department.'),
  ('department.delete',
   'Deactivate (soft-delete) a department so it no longer appears in active lists.'),
  ('department.manage_heads',
   'Assign or remove the designated head of a department.'),
  ('department.view_members',
   'View the list of employees who belong to a specific department.'),
  ('department.view_orgchart',
   'View the full department hierarchy including heads, member counts and parent/child relationships.'),

  -- ── Reference Data ─────────────────────────────────────────────────────────
  ('reference.view',
   'Browse all picklists and their values — for example designations, nationalities, marital statuses and expense categories.'),
  ('reference.create',
   'Add a new picklist category or a new value inside an existing picklist.'),
  ('reference.edit',
   'Edit the name, description or meta fields of an existing picklist or picklist value.'),
  ('reference.delete',
   'Permanently delete a picklist category (and all its values) or an individual picklist value.'),

  -- ── Projects ───────────────────────────────────────────────────────────────
  ('project.view',
   'View the project list. Required so employees can select a project when coding their expense reports.'),
  ('project.create',
   'Add a new project that employees can charge expenses against.'),
  ('project.edit',
   'Edit a project''s name, code, description or active status.'),
  ('project.delete',
   'Permanently delete a project record.'),

  -- ── Exchange Rates ─────────────────────────────────────────────────────────
  ('exchange_rate.view',
   'View the list of supported currencies and their current exchange rates.'),
  ('exchange_rate.create',
   'Add a new currency or enter a new exchange rate for an existing currency.'),
  ('exchange_rate.edit',
   'Update a currency''s ISO code, symbol or exchange rate value.'),
  ('exchange_rate.delete',
   'Remove a currency or exchange rate entry from the system.'),

  -- ── Reports ────────────────────────────────────────────────────────────────
  ('report.view',
   'Access the admin reports dashboard to view expense summaries, approvals and audit data.'),

  -- ── Security ───────────────────────────────────────────────────────────────
  ('security.assign_access',
   'Assign or change the role of a user — for example promoting a new joiner from Employee (ESS) to Manager.'),
  ('security.manage_roles',
   'Access the security screens: Role Management, Permission Catalog and Role Assignments. Allows changing what each role can do.')

) AS d(code, description)
WHERE permissions.code = d.code;
