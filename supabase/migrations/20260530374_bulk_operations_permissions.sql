-- =============================================================================
-- Migration 369 — Bulk Operations Framework: Permission Seeds
--
-- Seeds bulk_import + bulk_export permissions for all 15 module templates.
-- job_relationships.bulk_import / bulk_export already exist (mig 359) —
-- those INSERT rows use ON CONFLICT DO NOTHING to skip silently.
--
-- Module → permission-code prefix mapping:
--   personal_info      → personal_info.*    module: personal_info
--   contact_info       → contact_info.*     module: contact_info
--   address            → address.*          module: address
--   passport           → passport.*         module: passport
--   identification     → identification.*   module: identity_documents
--   emergency_contact  → emergency_contact.* module: emergency_contacts
--   employment         → employment.*       module: employment
--   job_relationships  → job_relationships.* module: job_relationships  (ALREADY SEEDED)
--   dependents         → dependents.*       module: employee
--   bank_accounts      → bank_accounts.*    module: bank_accounts
--   employees          → employees.*        module: employee
--   department         → department.*       module: departments
--   picklist           → picklist.*         module: reference
--   project            → project.*          module: reference
--   exchange_rate      → exchange_rate.*    module: exchange_rates_mgmt
--
-- Design spec: docs/bulk-operations-framework.md §7
-- Predecessor: mig 368 (schema)
-- Next: mig 370 (registry seeds)
-- =============================================================================


-- =============================================================================
-- Employee satellite modules (personal_info, contact_info, address, passport,
-- identity_documents, emergency_contacts, employment)
-- =============================================================================

DO $$
DECLARE
  v_mod_pi   uuid;
  v_mod_ci   uuid;
  v_mod_addr uuid;
  v_mod_pp   uuid;
  v_mod_id   uuid;
  v_mod_ec   uuid;
  v_mod_emp  uuid;
BEGIN
  SELECT id INTO v_mod_pi   FROM modules WHERE code = 'personal_info';
  SELECT id INTO v_mod_ci   FROM modules WHERE code = 'contact_info';
  SELECT id INTO v_mod_addr FROM modules WHERE code = 'address';
  SELECT id INTO v_mod_pp   FROM modules WHERE code = 'passport';
  SELECT id INTO v_mod_id   FROM modules WHERE code = 'identity_documents';
  SELECT id INTO v_mod_ec   FROM modules WHERE code = 'emergency_contacts';
  SELECT id INTO v_mod_emp  FROM modules WHERE code = 'employment';

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    -- personal_info
    ('personal_info.bulk_import', v_mod_pi,   'bulk_import',
     'Personal Info — Bulk Import',
     'Upload CSV to create/update personal information records in bulk. Bypasses workflow.'),
    ('personal_info.bulk_export', v_mod_pi,   'bulk_export',
     'Personal Info — Bulk Export',
     'Download current and historical personal information records as CSV.'),

    -- contact_info
    ('contact_info.bulk_import',  v_mod_ci,   'bulk_import',
     'Contact Info — Bulk Import',
     'Upload CSV to create/update employee contact (email/phone) records in bulk. Bypasses workflow.'),
    ('contact_info.bulk_export',  v_mod_ci,   'bulk_export',
     'Contact Info — Bulk Export',
     'Download current and historical contact information records as CSV.'),

    -- address
    ('address.bulk_import',       v_mod_addr, 'bulk_import',
     'Address — Bulk Import',
     'Upload CSV to create/update employee address records in bulk. Bypasses workflow.'),
    ('address.bulk_export',       v_mod_addr, 'bulk_export',
     'Address — Bulk Export',
     'Download current and historical address records as CSV.'),

    -- passport
    ('passport.bulk_import',      v_mod_pp,   'bulk_import',
     'Passport — Bulk Import',
     'Upload CSV to create/update employee passport records in bulk. Bypasses workflow.'),
    ('passport.bulk_export',      v_mod_pp,   'bulk_export',
     'Passport — Bulk Export',
     'Download current and historical passport records as CSV.'),

    -- identification (module: identity_documents)
    ('identification.bulk_import', v_mod_id,  'bulk_import',
     'Identification — Bulk Import',
     'Upload CSV to create/update employee identification document records in bulk. Bypasses workflow.'),
    ('identification.bulk_export', v_mod_id,  'bulk_export',
     'Identification — Bulk Export',
     'Download current and historical identification records as CSV.'),

    -- emergency_contact (module: emergency_contacts)
    ('emergency_contact.bulk_import', v_mod_ec, 'bulk_import',
     'Emergency Contact — Bulk Import',
     'Upload CSV to create/update employee emergency contact records in bulk. Bypasses workflow.'),
    ('emergency_contact.bulk_export', v_mod_ec, 'bulk_export',
     'Emergency Contact — Bulk Export',
     'Download current and historical emergency contact records as CSV.'),

    -- employment
    ('employment.bulk_import',    v_mod_emp,  'bulk_import',
     'Employment — Bulk Import',
     'Upload CSV to create/update employment detail records in bulk. Bypasses workflow.'),
    ('employment.bulk_export',    v_mod_emp,  'bulk_export',
     'Employment — Bulk Export',
     'Download current and historical employment detail records as CSV.')

  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- Set-snapshot satellite modules (dependents, bank_accounts, job_relationships)
-- job_relationships already seeded in mig 359 — ON CONFLICT DO NOTHING
-- =============================================================================

DO $$
DECLARE
  v_mod_emp  uuid;
  v_mod_bank uuid;
  v_mod_jr   uuid;
BEGIN
  SELECT id INTO v_mod_emp  FROM modules WHERE code = 'employee';
  SELECT id INTO v_mod_bank FROM modules WHERE code = 'bank_accounts';
  SELECT id INTO v_mod_jr   FROM modules WHERE code = 'job_relationships';

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    -- dependents (module: employee, same as dependents.view/edit)
    ('dependents.bulk_import',     v_mod_emp,  'bulk_import',
     'Dependents — Bulk Import',
     'Upload CSV to create/update employee dependent records in bulk. Bypasses workflow.'),
    ('dependents.bulk_export',     v_mod_emp,  'bulk_export',
     'Dependents — Bulk Export',
     'Download current and historical dependent records as CSV.'),

    -- bank_accounts
    ('bank_accounts.bulk_import',  v_mod_bank, 'bulk_import',
     'Bank Accounts — Bulk Import',
     'Upload CSV to create/update employee bank account records in bulk. Bypasses workflow.'),
    ('bank_accounts.bulk_export',  v_mod_bank, 'bulk_export',
     'Bank Accounts — Bulk Export',
     'Download current and historical bank account records as CSV.'),

    -- job_relationships (already seeded by mig 359 — DO NOTHING is safe)
    ('job_relationships.bulk_import', v_mod_jr, 'bulk_import',
     'Job Relationships — Bulk Import',
     'Upload CSV to create/update matrix manager assignments in bulk. Bypasses workflow.'),
    ('job_relationships.bulk_export', v_mod_jr, 'bulk_export',
     'Job Relationships — Bulk Export',
     'Download current and historical matrix manager assignment records as CSV.')

  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- Master employee + org modules (employees, department)
-- =============================================================================

DO $$
DECLARE
  v_mod_emp  uuid;
  v_mod_dept uuid;
BEGIN
  SELECT id INTO v_mod_emp  FROM modules WHERE code = 'employee';
  SELECT id INTO v_mod_dept FROM modules WHERE code = 'departments';

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    -- employees master
    ('employees.bulk_import',  v_mod_emp,  'bulk_import',
     'Employees — Bulk Import',
     'Upload CSV to create/update employee master records in bulk. Bypasses workflow.'),
    ('employees.bulk_export',  v_mod_emp,  'bulk_export',
     'Employees — Bulk Export',
     'Download current employee master records as CSV.'),

    -- department
    ('department.bulk_import', v_mod_dept, 'bulk_import',
     'Department — Bulk Import',
     'Upload CSV to create/update department records in bulk.'),
    ('department.bulk_export', v_mod_dept, 'bulk_export',
     'Department — Bulk Export',
     'Download current department records as CSV.')

  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- Admin reference / master tables (picklist, project, exchange_rate)
-- =============================================================================

DO $$
DECLARE
  v_mod_ref  uuid;
  v_mod_xr   uuid;
BEGIN
  SELECT id INTO v_mod_ref FROM modules WHERE code = 'reference';
  SELECT id INTO v_mod_xr  FROM modules WHERE code = 'exchange_rates_mgmt';

  INSERT INTO permissions (code, module_id, action, name, description)
  VALUES
    -- picklist (module: reference)
    ('picklist.bulk_import',      v_mod_ref, 'bulk_import',
     'Picklist — Bulk Import',
     'Upload CSV to create/update picklist values in bulk, including cascading values.'),
    ('picklist.bulk_export',      v_mod_ref, 'bulk_export',
     'Picklist — Bulk Export',
     'Download current picklist values as CSV.'),

    -- project (module: reference — same as project.view/edit)
    ('project.bulk_import',       v_mod_ref, 'bulk_import',
     'Project — Bulk Import',
     'Upload CSV to create/update project records in bulk.'),
    ('project.bulk_export',       v_mod_ref, 'bulk_export',
     'Project — Bulk Export',
     'Download current project records as CSV.'),

    -- exchange_rate (module: exchange_rates_mgmt)
    ('exchange_rate.bulk_import', v_mod_xr,  'bulk_import',
     'Exchange Rate — Bulk Import',
     'Upload CSV to create/update exchange rate records in bulk.'),
    ('exchange_rate.bulk_export', v_mod_xr,  'bulk_export',
     'Exchange Rate — Bulk Export',
     'Download current and historical exchange rate records as CSV.')

  ON CONFLICT (code) DO NOTHING;
END;
$$;


-- =============================================================================
-- Verification
-- =============================================================================

SELECT code, action, name
FROM   permissions
WHERE  code ~ '\.bulk_(import|export)$'
ORDER  BY code;

-- Expected: 30 rows (15 modules × 2)
SELECT COUNT(*) AS bulk_permission_count
FROM   permissions
WHERE  code ~ '\.bulk_(import|export)$';

-- =============================================================================
-- END OF MIGRATION 369
-- =============================================================================
