-- =============================================================================
-- Migration 370 — Bulk Operations Framework: Registry Seeds
--
-- Seeds 15 rows in bulk_template_registry — one per supported module.
-- schema_definition JSONB drives template CSV generation, exporter column
-- selection, and importer validation. See docs/bulk-operations-framework.md §5.
--
-- Template ordering in the UI dropdown (sort_order):
--   10  Personal Information
--   20  Contact Info
--   30  Address
--   40  Passport
--   50  Identification
--   60  Emergency Contact
--   70  Employment
--   80  Job Relationships
--   90  Dependents
--   100 Bank Accounts
--   110 Employees (master)
--   120 Departments
--   130 Picklist Values
--   140 Projects
--   150 Exchange Rates
--
-- Design spec: docs/bulk-operations-framework.md §13
-- Predecessor: mig 369 (permission seeds)
-- Next: mig 371 (processor RPC wrappers for modules lacking them)
-- =============================================================================


-- =============================================================================
-- 1. personal_info
-- Table: employee_personal
-- Columns: first_name, last_name, middle_name, gender, dob, nationality,
--          marital_status (+ photo_url excluded as binary)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'personal_info',
  'Personal Information',
  'Employee name, gender, date of birth, nationality, and marital status.',
  'ti-user',
  10,
  'personal_info.bulk_import',
  'personal_info.bulk_export',
  'upsert_personal_info',
  -- exporter_query: current state (one row per employee)
  $exq$
    SELECT
      e.employee_id              AS "Employee Code *",
      ep.first_name              AS "First Name *",
      ep.last_name               AS "Last Name *",
      ep.middle_name             AS "Middle Name",
      ep.gender                  AS "Gender",
      TO_CHAR(ep.dob, 'MM/DD/YYYY') AS "Date of Birth",
      ep.nationality             AS "Nationality (ISO3)",
      ep.marital_status          AS "Marital Status"
    FROM employee_personal ep
    JOIN employees e ON e.id = ep.employee_id
    ORDER BY e.employee_id
  $exq$,
  NULL, -- no timeline (non-effective-dated)
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true,'description','Existing employee code, e.g. EMP001'),
      jsonb_build_object('name','First Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Last Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Middle Name','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Gender','data_type','enum:Male,Female','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Date of Birth','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Nationality (ISO3)','data_type','code_country_iso','mandatory',false,'user_fillable',true,'description','ISO3 country code, e.g. IND, GBR'),
      jsonb_build_object('name','Marital Status','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 2. contact_info
-- Table: employee_contact
-- Columns: country_code, mobile, personal_email
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'contact_info',
  'Contact Information',
  'Employee personal email, mobile number, and country dialling code.',
  'ti-device-mobile',
  20,
  'contact_info.bulk_import',
  'contact_info.bulk_export',
  'upsert_contact_info',
  $exq$
    SELECT
      e.employee_id              AS "Employee Code *",
      ec.personal_email          AS "Personal Email",
      ec.country_code            AS "Country Code",
      ec.mobile                  AS "Mobile"
    FROM employee_contact ec
    JOIN employees e ON e.id = ec.employee_id
    ORDER BY e.employee_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Personal Email','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Country Code','data_type','text','mandatory',false,'user_fillable',true,'description','Dialling code prefix, e.g. +91, +44'),
      jsonb_build_object('name','Mobile','data_type','text','mandatory',false,'user_fillable',true,'description','Mobile number without country code'),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 3. address
-- Table: employee_addresses (UNIQUE on employee_id — one address per employee)
-- Columns: line1, line2, landmark, city, district, state, pin, country
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'address',
  'Address',
  'Employee residential/correspondence address. One record per employee.',
  'ti-map-pin',
  30,
  'address.bulk_import',
  'address.bulk_export',
  'upsert_employee_address',
  $exq$
    SELECT
      e.employee_id  AS "Employee Code *",
      ea.line1       AS "Line 1",
      ea.line2       AS "Line 2",
      ea.landmark    AS "Landmark",
      ea.city        AS "City",
      ea.district    AS "District",
      ea.state       AS "State",
      ea.pin         AS "Postal Code",
      ea.country     AS "Country (ISO3)"
    FROM employee_addresses ea
    JOIN employees e ON e.id = ea.employee_id
    ORDER BY e.employee_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Line 1','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Line 2','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Landmark','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','City','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','District','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','State','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Postal Code','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Country (ISO3)','data_type','code_country_iso','mandatory',false,'user_fillable',true,'description','ISO3 country code, e.g. IND, GBR'),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 4. passport
-- Table: passports (UNIQUE on employee_id — one passport per employee)
-- Columns: country, passport_number, issue_date, expiry_date
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'passport',
  'Passport',
  'Employee passport details. One active passport record per employee.',
  'ti-passport',
  40,
  'passport.bulk_import',
  'passport.bulk_export',
  'upsert_passport',
  $exq$
    SELECT
      e.employee_id                    AS "Employee Code *",
      p.passport_number                AS "Passport Number *",
      p.country                        AS "Country (ISO3)",
      TO_CHAR(p.issue_date, 'MM/DD/YYYY')   AS "Issue Date",
      TO_CHAR(p.expiry_date, 'MM/DD/YYYY')  AS "Expiry Date"
    FROM passports p
    JOIN employees e ON e.id = p.employee_id
    ORDER BY e.employee_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Passport Number *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Country (ISO3)','data_type','code_country_iso','mandatory',false,'user_fillable',true,'description','Issuing country ISO3 code, e.g. IND, GBR'),
      jsonb_build_object('name','Issue Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Expiry Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *','Passport Number *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *','Passport Number *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 5. identification
-- Table: identity_records
-- Columns: id_type, record_type, id_number, expiry, country
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'identification',
  'Identification',
  'Employee national ID and other identity document records.',
  'ti-id-badge',
  50,
  'identification.bulk_import',
  'identification.bulk_export',
  'upsert_identity_record',
  $exq$
    SELECT
      e.employee_id                   AS "Employee Code *",
      ir.id_type                      AS "ID Type *",
      ir.id_number                    AS "ID Number *",
      ir.country                      AS "Country (ISO3)",
      TO_CHAR(ir.expiry, 'MM/DD/YYYY') AS "Expiry Date"
    FROM identity_records ir
    JOIN employees e ON e.id = ir.employee_id
    ORDER BY e.employee_id, ir.id_type
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','ID Type *','data_type','text','mandatory',true,'user_fillable',true,'description','e.g. AADHAAR, PAN, NI, SSN'),
      jsonb_build_object('name','ID Number *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Country (ISO3)','data_type','code_country_iso','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Expiry Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *','ID Type *','ID Number *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *','ID Type *','ID Number *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 6. emergency_contact
-- Table: emergency_contacts
-- Columns: name, relationship, phone, alt_phone, email
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'emergency_contact',
  'Emergency Contact',
  'Employee emergency contact details.',
  'ti-emergency-bed',
  60,
  'emergency_contact.bulk_import',
  'emergency_contact.bulk_export',
  'upsert_emergency_contact',
  $exq$
    SELECT
      e.employee_id  AS "Employee Code *",
      ec.name        AS "Contact Name *",
      ec.relationship AS "Relationship",
      ec.phone       AS "Phone",
      ec.alt_phone   AS "Alt Phone",
      ec.email       AS "Email"
    FROM emergency_contacts ec
    JOIN employees e ON e.id = ec.employee_id
    ORDER BY e.employee_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Contact Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Relationship','data_type','text','mandatory',false,'user_fillable',true,'description','e.g. Spouse, Parent, Sibling'),
      jsonb_build_object('name','Phone','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Alt Phone','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Email','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 7. employment
-- Table: employee_employment (effective-dated, mig 351)
-- Columns: designation, job_title, dept_id→dept_code, manager_id→employee_code,
--          hire_date, end_date, work_country, work_location, base_currency_id→code, status
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'employment',
  'Employment Details',
  'Effective-dated employment details: designation, job title, department, manager, status, and work location.',
  'ti-briefcase',
  70,
  'employment.bulk_import',
  'employment.bulk_export',
  'upsert_employment_info',
  $exq$
    SELECT
      e.employee_id                         AS "Employee Code *",
      TO_CHAR(ee.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      ee.designation                         AS "Designation",
      ee.job_title                           AS "Job Title",
      d.dept_id                              AS "Department Code",
      mgr.employee_id                        AS "Manager Employee Code",
      TO_CHAR(ee.hire_date, 'MM/DD/YYYY')   AS "Hire Date",
      TO_CHAR(ee.end_date, 'MM/DD/YYYY')    AS "End Date",
      ee.work_country                        AS "Work Country (ISO3)",
      ee.work_location                       AS "Work Location",
      c.code                                 AS "Base Currency",
      ee.status::text                        AS "Status"
    FROM employee_employment ee
    JOIN employees e   ON e.id  = ee.employee_id
    LEFT JOIN departments d  ON d.id  = ee.dept_id
    LEFT JOIN employees mgr  ON mgr.id = ee.manager_id
    LEFT JOIN currencies c   ON c.id  = ee.base_currency_id
    WHERE ee.is_active = true
    ORDER BY e.employee_id
  $exq$,
  $hxq$
    SELECT
      e.employee_id                         AS "Employee Code *",
      TO_CHAR(ee.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      TO_CHAR(ee.effective_to, 'MM/DD/YYYY') AS "Slice End",
      ee.is_active                           AS "Slice Is Active",
      ee.designation                         AS "Designation",
      ee.job_title                           AS "Job Title",
      d.dept_id                              AS "Department Code",
      mgr.employee_id                        AS "Manager Employee Code",
      TO_CHAR(ee.hire_date, 'MM/DD/YYYY')   AS "Hire Date",
      TO_CHAR(ee.end_date, 'MM/DD/YYYY')    AS "End Date",
      ee.work_country                        AS "Work Country (ISO3)",
      ee.work_location                       AS "Work Location",
      c.code                                 AS "Base Currency",
      ee.status::text                        AS "Status"
    FROM employee_employment ee
    JOIN employees e   ON e.id  = ee.employee_id
    LEFT JOIN departments d  ON d.id  = ee.dept_id
    LEFT JOIN employees mgr  ON mgr.id = ee.manager_id
    LEFT JOIN currencies c   ON c.id  = ee.base_currency_id
    ORDER BY e.employee_id, ee.effective_from
  $hxq$,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true,'description','Date this employment slice takes effect; format mm/dd/yyyy'),
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Designation','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Job Title','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Department Code','data_type','code_department','mandatory',false,'user_fillable',true,'description','departments.dept_id, e.g. D001'),
      jsonb_build_object('name','Manager Employee Code','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Leave blank for no manager'),
      jsonb_build_object('name','Hire Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','End Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true,'description','Leave blank for active employees'),
      jsonb_build_object('name','Work Country (ISO3)','data_type','code_country_iso','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Work Location','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Base Currency','data_type','code_currency','mandatory',false,'user_fillable',true,'description','currencies.code, e.g. INR, USD'),
      jsonb_build_object('name','Status','data_type','enum:Active,Inactive,On Leave','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *'),
      jsonb_build_object('name','Department Name','data_type','display_label','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Department Code'),
      jsonb_build_object('name','id','data_type','uuid','mandatory',false,'user_fillable',false,'include_with_system_metadata',true)
    ),
    'natural_key', jsonb_build_array('Effective Date *','Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Effective Date *','Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 8. job_relationships
-- Tables: employee_job_relationship_set + employee_job_relationship_item
-- group_by_key: grouped by (Employee Code, Effective Date)
-- Natural key: (Effective Date, Employee Code, Relationship Code)
-- Fully specified in docs/job-relationships-design.md §16
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'job_relationships',
  'Job Relationships',
  'Matrix manager assignments per relationship type (PM01–OM03). Effective-dated set-snapshot.',
  'ti-users-group',
  80,
  'job_relationships.bulk_import',
  'job_relationships.bulk_export',
  'upsert_job_relationship_set',
  $exq$
    SELECT
      e.employee_id                            AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      i.relationship_code                      AS "Relationship Code *",
      mgr.employee_id                          AS "Value *"
    FROM employee_job_relationship_set s
    JOIN employee_job_relationship_item i ON i.set_id = s.id
    JOIN employees e   ON e.id   = s.employee_id
    JOIN employees mgr ON mgr.id = i.manager_employee_id
    WHERE s.is_active = true
    ORDER BY e.employee_id, i.relationship_code
  $exq$,
  $hxq$
    SELECT
      e.employee_id                            AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      TO_CHAR(s.effective_to,   'MM/DD/YYYY') AS "Slice End",
      s.is_active                              AS "Slice Is Active",
      i.relationship_code                      AS "Relationship Code *",
      mgr.employee_id                          AS "Value *"
    FROM employee_job_relationship_set s
    JOIN employee_job_relationship_item i ON i.set_id = s.id
    JOIN employees e   ON e.id   = s.employee_id
    JOIN employees mgr ON mgr.id = i.manager_employee_id
    ORDER BY e.employee_id, s.effective_from, i.relationship_code
  $hxq$,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true,'description','Date this relationship snapshot takes effect; format mm/dd/yyyy'),
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true,'description','The employee whose matrix manager is being assigned'),
      jsonb_build_object('name','Relationship Code *','data_type','code_picklist:JOB_RELATIONSHIP_TYPE','mandatory',true,'user_fillable',true,'description','PM01, PM02, PM03, OM01, OM02, or OM03'),
      jsonb_build_object('name','Value *','data_type','code_employee_or_keyword:DELETE','mandatory',true,'user_fillable',true,'description','Employee code of the matrix manager, or DELETE to remove this code from the snapshot'),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *'),
      jsonb_build_object('name','Relationship Label','data_type','display_label','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Relationship Code *'),
      jsonb_build_object('name','Manager Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Value *')
    ),
    'natural_key', jsonb_build_array('Effective Date *','Employee Code *','Relationship Code *'),
    'row_processor', 'group_by_key',
    'group_by', jsonb_build_array('Employee Code *','Effective Date *')
  ),
  ARRAY['Effective Date *','Employee Code *','Relationship Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 9. dependents
-- Tables: employee_dependent_set + employee_dependent_item
-- group_by_key: grouped by (Employee Code, Effective Date)
-- Natural key: (Effective Date, Employee Code, Dependent Code)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'dependents',
  'Dependents',
  'Employee dependent records. Effective-dated set-snapshot; each row is one dependent in a snapshot.',
  'ti-users',
  90,
  'dependents.bulk_import',
  'dependents.bulk_export',
  'upsert_dependent_set',
  $exq$
    SELECT
      e.employee_id                            AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      i.dependent_code                         AS "Dependent Code *",
      i.dependent_name                         AS "Dependent Name *",
      i.relationship_type                      AS "Relationship Code *",
      TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')  AS "Date of Birth",
      CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
    FROM employee_dependent_set s
    JOIN employee_dependent_item i ON i.set_id = s.id
    JOIN employees e ON e.id = s.employee_id
    WHERE s.is_active = true
    ORDER BY e.employee_id, i.dependent_code
  $exq$,
  $hxq$
    SELECT
      e.employee_id                            AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
      TO_CHAR(s.effective_to,   'MM/DD/YYYY') AS "Slice End",
      s.is_active                              AS "Slice Is Active",
      i.dependent_code                         AS "Dependent Code *",
      i.dependent_name                         AS "Dependent Name *",
      i.relationship_type                      AS "Relationship Code *",
      TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')  AS "Date of Birth",
      CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
    FROM employee_dependent_set s
    JOIN employee_dependent_item i ON i.set_id = s.id
    JOIN employees e ON e.id = s.employee_id
    ORDER BY e.employee_id, s.effective_from, i.dependent_code
  $hxq$,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true,'description','Date this dependent snapshot takes effect'),
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Dependent Code *','data_type','text','mandatory',true,'user_fillable',true,'description','Short code uniquely identifying the dependent within this employee, e.g. DEP01'),
      jsonb_build_object('name','Dependent Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Relationship Code *','data_type','code_picklist:DEPENDENT_RELATIONSHIP_TYPE','mandatory',true,'user_fillable',true,'description','Picklist ref_id, e.g. SPOUSE, CHILD'),
      jsonb_build_object('name','Date of Birth','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Insurance Eligible','data_type','yesno','mandatory',false,'user_fillable',true,'description','Yes or No'),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *'),
      jsonb_build_object('name','Relationship Label','data_type','display_label','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Relationship Code *')
    ),
    'natural_key', jsonb_build_array('Effective Date *','Employee Code *','Dependent Code *'),
    'row_processor', 'group_by_key',
    'group_by', jsonb_build_array('Employee Code *','Effective Date *')
  ),
  ARRAY['Effective Date *','Employee Code *','Dependent Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 10. bank_accounts
-- Tables: employee_bank_account_set + employee_bank_account_item
-- group_by_key: grouped by (Employee Code, Effective Date)
-- Natural key: (Effective Date, Employee Code, Account Group Id)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'bank_accounts',
  'Bank Accounts',
  'Employee bank account records. Effective-dated set-snapshot; each row is one account in a snapshot.',
  'ti-building-bank',
  100,
  'bank_accounts.bulk_import',
  'bank_accounts.bulk_export',
  'upsert_bank_account_set',
  $exq$
    SELECT
      e.employee_id                              AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY')  AS "Effective Date *",
      i.bank_account_group_id::text              AS "Account Group Id *",
      i.country_code                             AS "Country (ISO3) *",
      i.currency_code                            AS "Currency Code *",
      i.bank_name                                AS "Bank Name *",
      i.branch_name                              AS "Branch Name",
      i.branch_code                              AS "Branch Code",
      i.account_holder_name                      AS "Account Holder Name *",
      i.account_number                           AS "Account Number *",
      i.ifsc_code                                AS "IFSC Code",
      i.iban                                     AS "IBAN",
      i.swift_bic                                AS "SWIFT / BIC",
      CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary"
    FROM employee_bank_account_set s
    JOIN employee_bank_account_item i ON i.set_id = s.id
    JOIN employees e ON e.id = s.employee_id
    WHERE s.is_active = true
    ORDER BY e.employee_id, i.is_primary DESC, i.bank_name
  $exq$,
  $hxq$
    SELECT
      e.employee_id                              AS "Employee Code *",
      TO_CHAR(s.effective_from, 'MM/DD/YYYY')  AS "Effective Date *",
      TO_CHAR(s.effective_to,   'MM/DD/YYYY')  AS "Slice End",
      s.is_active                               AS "Slice Is Active",
      i.bank_account_group_id::text              AS "Account Group Id *",
      i.country_code                             AS "Country (ISO3) *",
      i.currency_code                            AS "Currency Code *",
      i.bank_name                                AS "Bank Name *",
      i.branch_name                              AS "Branch Name",
      i.branch_code                              AS "Branch Code",
      i.account_holder_name                      AS "Account Holder Name *",
      i.account_number                           AS "Account Number *",
      i.ifsc_code                                AS "IFSC Code",
      i.iban                                     AS "IBAN",
      i.swift_bic                                AS "SWIFT / BIC",
      CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary"
    FROM employee_bank_account_set s
    JOIN employee_bank_account_item i ON i.set_id = s.id
    JOIN employees e ON e.id = s.employee_id
    ORDER BY e.employee_id, s.effective_from, i.bank_name
  $hxq$,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Account Group Id *','data_type','text','mandatory',true,'user_fillable',true,'description','UUID identifying this account group; auto-generated on first import if blank'),
      jsonb_build_object('name','Country (ISO3) *','data_type','code_country_iso','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Currency Code *','data_type','code_currency','mandatory',true,'user_fillable',true,'description','e.g. INR, USD, GBP'),
      jsonb_build_object('name','Bank Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Branch Name','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Branch Code','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Account Holder Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Account Number *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','IFSC Code','data_type','text','mandatory',false,'user_fillable',true,'description','Required for INR accounts'),
      jsonb_build_object('name','IBAN','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','SWIFT / BIC','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Is Primary','data_type','yesno','mandatory',false,'user_fillable',true,'description','Yes for the primary payout account'),
      jsonb_build_object('name','Employee Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Employee Code *')
    ),
    'natural_key', jsonb_build_array('Effective Date *','Employee Code *','Account Group Id *'),
    'row_processor', 'group_by_key',
    'group_by', jsonb_build_array('Employee Code *','Effective Date *')
  ),
  ARRAY['Effective Date *','Employee Code *','Account Group Id *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 11. employees (master)
-- Table: employees
-- Columns: employee_id, name, business_email, designation, job_title,
--          dept_id→dept_code, manager_id→employee_code, hire_date, end_date, status
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'employees',
  'Employees (Master)',
  'Employee master records: code, name, email, department, manager, hire date, and status.',
  'ti-user-circle',
  110,
  'employees.bulk_import',
  'employees.bulk_export',
  'upsert_employee_master',
  $exq$
    SELECT
      e.employee_id           AS "Employee Code *",
      e.name                  AS "Full Name *",
      e.business_email        AS "Business Email",
      e.designation           AS "Designation",
      e.job_title             AS "Job Title",
      d.dept_id               AS "Department Code",
      mgr.employee_id         AS "Manager Employee Code",
      TO_CHAR(e.hire_date, 'MM/DD/YYYY') AS "Hire Date",
      TO_CHAR(e.end_date,  'MM/DD/YYYY') AS "End Date",
      e.status::text          AS "Status"
    FROM employees e
    LEFT JOIN departments d   ON d.id  = e.dept_id
    LEFT JOIN employees mgr   ON mgr.id = e.manager_id
    ORDER BY e.employee_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *','data_type','text','mandatory',true,'user_fillable',true,'description','Unique employee code, e.g. EMP001. Used as the natural key — must not change after creation.'),
      jsonb_build_object('name','Full Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','Business Email','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Designation','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Job Title','data_type','text','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Department Code','data_type','code_department','mandatory',false,'user_fillable',true,'description','departments.dept_id, e.g. D001'),
      jsonb_build_object('name','Manager Employee Code','data_type','code_employee','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Hire Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','End Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Status','data_type','enum:Active,Inactive','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Department Name','data_type','display_label','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Department Code'),
      jsonb_build_object('name','Manager Name','data_type','display_name','mandatory',false,'user_fillable',false,'include_with_system_metadata',true,'computed_from','Manager Employee Code'),
      jsonb_build_object('name','id','data_type','uuid','mandatory',false,'user_fillable',false,'include_with_system_metadata',true)
    ),
    'natural_key', jsonb_build_array('Employee Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Employee Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 12. department
-- Table: departments
-- Columns: dept_id, name (no parent_id in current schema — no code column)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'department',
  'Departments',
  'Department master records: code and name.',
  'ti-building',
  120,
  'department.bulk_import',
  'department.bulk_export',
  'upsert_department',
  $exq$
    SELECT
      d.dept_id  AS "Department Code *",
      d.name     AS "Department Name *"
    FROM departments d
    WHERE d.deleted_at IS NULL
    ORDER BY d.dept_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Department Code *','data_type','text','mandatory',true,'user_fillable',true,'description','Unique department code, e.g. D001. Natural key — must not change after creation.'),
      jsonb_build_object('name','Department Name *','data_type','text','mandatory',true,'user_fillable',true),
      jsonb_build_object('name','id','data_type','uuid','mandatory',false,'user_fillable',false,'include_with_system_metadata',true)
    ),
    'natural_key', jsonb_build_array('Department Code *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Department Code *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 13. picklist
-- Tables: picklists + picklist_values
-- Natural key: (Picklist Id, Ref Id)
-- Supports cascading via Parent Picklist Id + Parent Ref Id
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'picklist',
  'Reference Picklist Values',
  'Picklist values for all reference data dropdowns. Supports cascading parent-child values and Meta JSON.',
  'ti-list',
  130,
  'picklist.bulk_import',
  'picklist.bulk_export',
  'upsert_picklist_value',
  $exq$
    SELECT
      pl.id::text            AS "Picklist Id *",
      pv.ref_id              AS "Ref Id *",
      pv.value               AS "Value *",
      parent_pl.id::text     AS "Parent Picklist Id",
      parent_pv.ref_id       AS "Parent Ref Id",
      pv.sort_order::text    AS "Sort Order",
      CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
      pv.meta::text          AS "Meta"
    FROM picklist_values pv
    JOIN picklists pl ON pl.id = pv.picklist_id
    LEFT JOIN picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
    LEFT JOIN picklists parent_pl ON parent_pl.id = parent_pv.picklist_id
    ORDER BY pl.id, pv.sort_order, pv.ref_id
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Picklist Id *','data_type','text','mandatory',true,'user_fillable',true,'description','The picklist identifier, e.g. ID_COUNTRY, JOB_RELATIONSHIP_TYPE'),
      jsonb_build_object('name','Ref Id *','data_type','text','mandatory',true,'user_fillable',true,'description','Short code uniquely identifying this value within its picklist, e.g. IND, PM01'),
      jsonb_build_object('name','Value *','data_type','text','mandatory',true,'user_fillable',true,'description','Display label, e.g. India, Project Manager'),
      jsonb_build_object('name','Parent Picklist Id','data_type','text','mandatory',false,'user_fillable',true,'description','For cascading values: the parent picklist identifier'),
      jsonb_build_object('name','Parent Ref Id','data_type','text','mandatory',false,'user_fillable',true,'description','For cascading values: the ref_id of the parent value'),
      jsonb_build_object('name','Sort Order','data_type','integer','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Active','data_type','yesno','mandatory',false,'user_fillable',true,'description','Yes (default) or No to deactivate'),
      jsonb_build_object('name','Meta','data_type','text','mandatory',false,'user_fillable',true,'description','Optional JSON metadata, e.g. {"isoCode":"IND"}. Must be valid JSON if provided.')
    ),
    'natural_key', jsonb_build_array('Picklist Id *','Ref Id *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Picklist Id *','Ref Id *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 14. project
-- Table: projects
-- Note: projects has no project_code column (UUID PK + name only).
--       Natural key is 'Project Name *' until a code column is added (mig 371+).
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'project',
  'Projects',
  'Project master records used for expense line-item coding.',
  'ti-clipboard-list',
  140,
  'project.bulk_import',
  'project.bulk_export',
  'upsert_project',
  $exq$
    SELECT
      p.name                              AS "Project Name *",
      TO_CHAR(p.start_date, 'MM/DD/YYYY') AS "Start Date",
      TO_CHAR(p.end_date,   'MM/DD/YYYY') AS "End Date",
      CASE WHEN p.active THEN 'Yes' ELSE 'No' END AS "Active"
    FROM projects p
    ORDER BY p.name
  $exq$,
  NULL,
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Project Name *','data_type','text','mandatory',true,'user_fillable',true,'description','Project name — used as the natural key (unique). Changing the name creates a new project.'),
      jsonb_build_object('name','Start Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','End Date','data_type','date_mmddyyyy','mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Active','data_type','yesno','mandatory',false,'user_fillable',true,'description','Yes (default) or No to deactivate'),
      jsonb_build_object('name','id','data_type','uuid','mandatory',false,'user_fillable',false,'include_with_system_metadata',true)
    ),
    'natural_key', jsonb_build_array('Project Name *'),
    'row_processor', 'per_row'
  ),
  ARRAY['Project Name *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- 15. exchange_rate
-- Table: exchange_rates
-- from_currency_id + to_currency_id are UUIDs resolved via currencies.code
-- Natural key: (From Currency, To Currency, Effective Date)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'exchange_rate',
  'Exchange Rates',
  'Date-effective exchange rates between currency pairs. One rate per (from, to, date) combination.',
  'ti-currency-dollar',
  150,
  'exchange_rate.bulk_import',
  'exchange_rate.bulk_export',
  'upsert_exchange_rate',
  $exq$
    SELECT
      fc.code                                  AS "From Currency *",
      tc.code                                  AS "To Currency *",
      TO_CHAR(er.effective_date, 'MM/DD/YYYY') AS "Effective Date *",
      er.rate::text                            AS "Rate *"
    FROM exchange_rates er
    JOIN currencies fc ON fc.id = er.from_currency_id
    JOIN currencies tc ON tc.id = er.to_currency_id
    ORDER BY fc.code, tc.code, er.effective_date
  $exq$,
  $hxq$
    SELECT
      fc.code                                  AS "From Currency *",
      tc.code                                  AS "To Currency *",
      TO_CHAR(er.effective_date, 'MM/DD/YYYY') AS "Effective Date *",
      er.rate::text                            AS "Rate *"
    FROM exchange_rates er
    JOIN currencies fc ON fc.id = er.from_currency_id
    JOIN currencies tc ON tc.id = er.to_currency_id
    ORDER BY fc.code, tc.code, er.effective_date
  $hxq$,  -- history = same as current (all rows are timeline already)
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','From Currency *','data_type','code_currency','mandatory',true,'user_fillable',true,'description','Source currency code, e.g. INR, USD'),
      jsonb_build_object('name','To Currency *','data_type','code_currency','mandatory',true,'user_fillable',true,'description','Target currency code, e.g. USD, GBP'),
      jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true,'description','Date from which this rate applies'),
      jsonb_build_object('name','Rate *','data_type','text','mandatory',true,'user_fillable',true,'description','Decimal exchange rate, e.g. 0.012000. Re-importing on an existing (from, to, date) updates the rate.')
    ),
    'natural_key', jsonb_build_array('From Currency *','To Currency *','Effective Date *'),
    'row_processor', 'per_row'
  ),
  ARRAY['From Currency *','To Currency *','Effective Date *']
)
ON CONFLICT (template_code) DO UPDATE
  SET display_label=EXCLUDED.display_label, description=EXCLUDED.description,
      schema_definition=EXCLUDED.schema_definition, updated_at=NOW();


-- =============================================================================
-- Verification
-- =============================================================================

SELECT template_code, display_label, sort_order,
       permission_import, permission_export, processor_rpc,
       jsonb_array_length(schema_definition->'columns') AS col_count
FROM   bulk_template_registry
ORDER  BY sort_order;

-- Expected: 15 rows
SELECT COUNT(*) AS registry_row_count FROM bulk_template_registry;

-- Check all permission codes exist
SELECT r.template_code, r.permission_import,
       (SELECT code FROM permissions WHERE code = r.permission_import) AS import_perm_exists,
       (SELECT code FROM permissions WHERE code = r.permission_export) AS export_perm_exists
FROM   bulk_template_registry r
ORDER  BY r.sort_order;

-- =============================================================================
-- END OF MIGRATION 370
-- =============================================================================
