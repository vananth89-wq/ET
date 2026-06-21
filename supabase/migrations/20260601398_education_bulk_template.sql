-- =============================================================================
-- Migration 398 — Education Module: Bulk Template Registry + Export RPC
--
-- TWO CHANGES:
--
-- 1. Seed education row in bulk_template_registry (16th template, sort_order=160).
--    processor_rpc = 'upsert_education'.
--
-- 2. CREATE OR REPLACE bulk_export — full 16-WHEN body.
--    Postgres requires the full body on CREATE OR REPLACE; this replaces mig 377
--    (15 WHEN clauses) with an identical copy plus the new 'education' clause.
--    All 15 existing clauses are reproduced verbatim.
--
-- Design spec: docs/education-design.md §6; docs/bulk-operations-framework.md §13
-- Predecessor: mig 397 (workflow branches)
-- =============================================================================


-- =============================================================================
-- 1. Bulk template registry seed — education (16th template)
-- =============================================================================

INSERT INTO bulk_template_registry (
  template_code, display_label, description, icon, sort_order,
  permission_import, permission_export,
  processor_rpc, exporter_query, history_exporter_query,
  schema_definition, natural_key
)
VALUES (
  'education',
  'Education',
  'Employee academic and professional qualifications: degree, institution, dates, completion status.',
  'ti-school',
  160,
  'education.bulk_import',
  'education.bulk_export',
  'upsert_education',
  -- exporter_query (current / active records)
  $exq$
    SELECT
      e.employee_id                              AS "Employee Code *",
      ee.education_level                         AS "Education Level Code *",
      ee.degree                                  AS "Degree *",
      ee.institution                             AS "Institution *",
      ee.field_of_study                          AS "Field of Study",
      TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
      TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
      ee.completion_status                        AS "Completion Status Code *",
      ee.grade_or_gpa                            AS "Grade / GPA",
      CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification"
    FROM employee_education ee
    JOIN employees e ON e.id = ee.employee_id
    WHERE ee.is_active = true
    ORDER BY e.employee_id, ee.is_highest_qualification DESC, ee.end_date DESC NULLS FIRST
  $exq$,
  -- history_exporter_query (includes removed rows)
  $hxq$
    SELECT
      e.employee_id                              AS "Employee Code *",
      ee.education_level                         AS "Education Level Code *",
      ee.degree                                  AS "Degree *",
      ee.institution                             AS "Institution *",
      ee.field_of_study                          AS "Field of Study",
      TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
      TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
      ee.completion_status                        AS "Completion Status Code *",
      ee.grade_or_gpa                            AS "Grade / GPA",
      CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification",
      CASE WHEN ee.is_active THEN 'Yes' ELSE 'No' END                AS "Is Active"
    FROM employee_education ee
    JOIN employees e ON e.id = ee.employee_id
    ORDER BY e.employee_id, ee.is_active DESC, ee.end_date DESC NULLS FIRST
  $hxq$,
  -- schema_definition
  jsonb_build_object(
    'columns', jsonb_build_array(
      jsonb_build_object('name','Employee Code *',         'data_type','code_employee',          'mandatory',true, 'user_fillable',true,  'description','Existing employee code e.g. EMP001'),
      jsonb_build_object('name','Education Level Code *',  'data_type','code_picklist:EDUCATION_LEVEL', 'mandatory',true, 'user_fillable',true,  'description','Picklist ref_id e.g. EDU03'),
      jsonb_build_object('name','Degree *',                'data_type','text',                   'mandatory',true, 'user_fillable',true,  'description','e.g. B.Tech in Computer Science'),
      jsonb_build_object('name','Institution *',           'data_type','text',                   'mandatory',true, 'user_fillable',true,  'description','e.g. Anna University'),
      jsonb_build_object('name','Field of Study',          'data_type','text',                   'mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Start Date *',            'data_type','date_mmddyyyy',          'mandatory',true, 'user_fillable',true),
      jsonb_build_object('name','End Date',                'data_type','date_mmddyyyy',          'mandatory',false,'user_fillable',true,  'description','Leave blank when Pursuing'),
      jsonb_build_object('name','Completion Status Code *','data_type','code_picklist:COMPLETION_STATUS','mandatory',true,'user_fillable',true,'description','e.g. ES01=Completed ES02=Pursuing'),
      jsonb_build_object('name','Grade / GPA',             'data_type','text',                   'mandatory',false,'user_fillable',true),
      jsonb_build_object('name','Highest Qualification',   'data_type','enum:Yes,No',            'mandatory',false,'user_fillable',true,  'description','At most one Yes per employee')
    ),
    'notes', 'Education Level and Completion Status use picklist ref_id codes. '
             'Highest Qualification: at most one Yes per employee — the import processor performs the atomic swap automatically.'
  ),
  -- natural_key: employee_id + education_level + institution + start_date
  ARRAY['Employee Code *', 'Education Level Code *', 'Institution *', 'Start Date *']
)
ON CONFLICT (template_code) DO UPDATE SET
  display_label           = EXCLUDED.display_label,
  description             = EXCLUDED.description,
  sort_order              = EXCLUDED.sort_order,
  permission_import       = EXCLUDED.permission_import,
  permission_export       = EXCLUDED.permission_export,
  processor_rpc           = EXCLUDED.processor_rpc,
  exporter_query          = EXCLUDED.exporter_query,
  history_exporter_query  = EXCLUDED.history_exporter_query,
  schema_definition       = EXCLUDED.schema_definition,
  natural_key             = EXCLUDED.natural_key;


-- =============================================================================
-- 2. bulk_export — 16-WHEN body (replaces mig 377 which had 15)
--
-- All 15 existing WHEN clauses reproduced verbatim from mig 377.
-- New clause: 16. education
-- =============================================================================

DROP FUNCTION IF EXISTS bulk_export(TEXT, BOOLEAN, TEXT);

CREATE OR REPLACE FUNCTION bulk_export(
  p_template_code    TEXT,
  p_include_inactive BOOLEAN DEFAULT false,
  p_mode             TEXT    DEFAULT 'current'
)
RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can(p_template_code, 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_export required', p_template_code
      USING ERRCODE = '42501';
  END IF;

  CASE p_template_code

    -- =========================================================================
    -- 1. personal_info
    -- =========================================================================
    WHEN 'personal_info' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                              AS "Employee Code *",
            ep.first_name                              AS "First Name *",
            ep.last_name                               AS "Last Name *",
            ep.middle_name                             AS "Middle Name",
            ep.gender                                  AS "Gender",
            TO_CHAR(ep.dob, 'MM/DD/YYYY')             AS "Date of Birth",
            ep.nationality                             AS "Nationality (ISO3)",
            ep.marital_status                          AS "Marital Status"
          FROM   employee_personal ep
          JOIN   employees e ON e.id = ep.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 2. contact_info
    -- =========================================================================
    WHEN 'contact_info' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id    AS "Employee Code *",
            ec.personal_email AS "Personal Email",
            ec.country_code  AS "Country Code",
            ec.mobile        AS "Mobile"
          FROM   employee_contact ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 3. address
    -- =========================================================================
    WHEN 'address' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
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
          FROM   employee_addresses ea
          JOIN   employees e ON e.id = ea.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 4. passport
    -- =========================================================================
    WHEN 'passport' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            p.passport_number                            AS "Passport Number *",
            p.country                                    AS "Country (ISO3)",
            TO_CHAR(p.issue_date,  'MM/DD/YYYY')        AS "Issue Date",
            TO_CHAR(p.expiry_date, 'MM/DD/YYYY')        AS "Expiry Date"
          FROM   passports p
          JOIN   employees e ON e.id = p.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 5. identification
    -- =========================================================================
    WHEN 'identification' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                              AS "Employee Code *",
            ir.id_type                                 AS "ID Type *",
            ir.id_number                               AS "ID Number *",
            ir.country                                 AS "Country (ISO3)",
            TO_CHAR(ir.expiry, 'MM/DD/YYYY')          AS "Expiry Date"
          FROM   identity_records ir
          JOIN   employees e ON e.id = ir.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ir.id_type
        ) r;

    -- =========================================================================
    -- 6. emergency_contact
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id   AS "Employee Code *",
            ec.name         AS "Contact Name *",
            ec.relationship AS "Relationship",
            ec.phone        AS "Phone",
            ec.alt_phone    AS "Alt Phone",
            ec.email        AS "Email"
          FROM   emergency_contacts ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ec.created_at
        ) r;

    -- =========================================================================
    -- 7. employment
    -- =========================================================================
    WHEN 'employment' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(ee.effective_from, 'MM/DD/YYYY')  AS "Effective Date *",
              TO_CHAR(ee.effective_to,   'MM/DD/YYYY')  AS "Slice End",
              ee.is_active                               AS "Slice Is Active",
              ee.designation                             AS "Designation",
              ee.job_title                               AS "Job Title",
              d.dept_id                                  AS "Department Code",
              mgr.employee_id                            AS "Manager Employee Code",
              TO_CHAR(ee.hire_date, 'MM/DD/YYYY')       AS "Hire Date",
              TO_CHAR(ee.end_date,  'MM/DD/YYYY')       AS "End Date",
              ee.work_country                            AS "Work Country (ISO3)",
              ee.work_location                           AS "Work Location",
              c.code                                     AS "Base Currency",
              ee.status::text                            AS "Status"
            FROM   employee_employment ee
            JOIN   employees e   ON e.id   = ee.employee_id
            LEFT JOIN departments d  ON d.id   = ee.dept_id
            LEFT JOIN employees mgr  ON mgr.id = ee.manager_id
            LEFT JOIN currencies c   ON c.id   = ee.base_currency_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, ee.effective_from
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(ee.effective_from, 'MM/DD/YYYY')  AS "Effective Date *",
              ee.designation                             AS "Designation",
              ee.job_title                               AS "Job Title",
              d.dept_id                                  AS "Department Code",
              mgr.employee_id                            AS "Manager Employee Code",
              TO_CHAR(ee.hire_date, 'MM/DD/YYYY')       AS "Hire Date",
              TO_CHAR(ee.end_date,  'MM/DD/YYYY')       AS "End Date",
              ee.work_country                            AS "Work Country (ISO3)",
              ee.work_location                           AS "Work Location",
              c.code                                     AS "Base Currency",
              ee.status::text                            AS "Status"
            FROM   employee_employment ee
            JOIN   employees e   ON e.id   = ee.employee_id
            LEFT JOIN departments d  ON d.id   = ee.dept_id
            LEFT JOIN employees mgr  ON mgr.id = ee.manager_id
            LEFT JOIN currencies c   ON c.id   = ee.base_currency_id
            WHERE  ee.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id
          ) r;
      END IF;

    -- =========================================================================
    -- 8. job_relationships
    -- =========================================================================
    WHEN 'job_relationships' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY')   AS "Slice End",
              s.is_active                                AS "Slice Is Active",
              i.relationship_code                        AS "Relationship Code *",
              mgr.employee_id                            AS "Value *"
            FROM   employee_job_relationship_set s
            JOIN   employee_job_relationship_item i ON i.set_id = s.id
            JOIN   employees e   ON e.id   = s.employee_id
            JOIN   employees mgr ON mgr.id = i.manager_employee_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, s.effective_from, i.relationship_code
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              i.relationship_code                        AS "Relationship Code *",
              mgr.employee_id                            AS "Value *"
            FROM   employee_job_relationship_set s
            JOIN   employee_job_relationship_item i ON i.set_id = s.id
            JOIN   employees e   ON e.id   = s.employee_id
            JOIN   employees mgr ON mgr.id = i.manager_employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.relationship_code
          ) r;
      END IF;

    -- =========================================================================
    -- 9. dependents
    -- =========================================================================
    WHEN 'dependents' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY')   AS "Slice End",
              s.is_active                                AS "Slice Is Active",
              i.dependent_code                           AS "Dependent Code *",
              i.dependent_name                           AS "Dependent Name *",
              i.relationship_type                        AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')    AS "Date of Birth",
              CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
            FROM   employee_dependent_set s
            JOIN   employee_dependent_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, s.effective_from, i.dependent_code
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              i.dependent_code                           AS "Dependent Code *",
              i.dependent_name                           AS "Dependent Name *",
              i.relationship_type                        AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')    AS "Date of Birth",
              CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
            FROM   employee_dependent_set s
            JOIN   employee_dependent_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.dependent_code
          ) r;
      END IF;

    -- =========================================================================
    -- 10. bank_accounts
    -- =========================================================================
    WHEN 'bank_accounts' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY')   AS "Slice End",
              s.is_active                                AS "Slice Is Active",
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
            FROM   employee_bank_account_set s
            JOIN   employee_bank_account_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, s.effective_from, i.bank_name
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
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
            FROM   employee_bank_account_set s
            JOIN   employee_bank_account_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.is_primary DESC, i.bank_name
          ) r;
      END IF;

    -- =========================================================================
    -- 11. employees (master)
    -- =========================================================================
    WHEN 'employees' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                          AS "Employee Code *",
            e.name                                 AS "Full Name *",
            e.business_email                       AS "Business Email",
            e.designation                          AS "Designation",
            e.job_title                            AS "Job Title",
            d.dept_id                              AS "Department Code",
            mgr.employee_id                        AS "Manager Employee Code",
            TO_CHAR(e.hire_date, 'MM/DD/YYYY')    AS "Hire Date",
            TO_CHAR(e.end_date,  'MM/DD/YYYY')    AS "End Date",
            e.status::text                         AS "Status"
          FROM   employees e
          LEFT JOIN departments d   ON d.id  = e.dept_id
          LEFT JOIN employees mgr   ON mgr.id = e.manager_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
            AND  e.status NOT IN ('Draft', 'Incomplete')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 12. department
    -- =========================================================================
    WHEN 'department' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            d.dept_id  AS "Department Code *",
            d.name     AS "Department Name *"
          FROM   departments d
          WHERE  d.deleted_at IS NULL
          ORDER  BY d.dept_id
        ) r;

    -- =========================================================================
    -- 13. picklist
    -- =========================================================================
    WHEN 'picklist' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            pl.id::text             AS "Picklist Id *",
            pv.ref_id               AS "Ref Id *",
            pv.value                AS "Value *",
            parent_pl.id::text      AS "Parent Picklist Id",
            parent_pv.ref_id        AS "Parent Ref Id",
            CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
            pv.meta::text           AS "Meta"
          FROM   picklist_values pv
          JOIN   picklists pl ON pl.id = pv.picklist_id
          LEFT JOIN picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
          LEFT JOIN picklists parent_pl ON parent_pl.id = parent_pv.picklist_id
          WHERE  (p_include_inactive OR pv.active = true)
          ORDER  BY pl.id, pv.ref_id
        ) r;

    -- =========================================================================
    -- 14. project
    -- =========================================================================
    WHEN 'project' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            p.name                               AS "Project Name *",
            TO_CHAR(p.start_date, 'MM/DD/YYYY') AS "Start Date",
            TO_CHAR(p.end_date,   'MM/DD/YYYY') AS "End Date",
            CASE WHEN p.active THEN 'Yes' ELSE 'No' END AS "Active"
          FROM   projects p
          WHERE  (p_include_inactive OR p.active = true)
          ORDER  BY p.name
        ) r;

    -- =========================================================================
    -- 15. exchange_rate
    -- =========================================================================
    WHEN 'exchange_rate' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            fc.code                                  AS "From Currency *",
            tc.code                                  AS "To Currency *",
            TO_CHAR(er.effective_date, 'MM/DD/YYYY') AS "Effective Date *",
            er.rate::text                            AS "Rate *"
          FROM   exchange_rates er
          JOIN   currencies fc ON fc.id = er.from_currency_id
          JOIN   currencies tc ON tc.id = er.to_currency_id
          ORDER  BY fc.code, tc.code, er.effective_date
        ) r;

    -- =========================================================================
    -- 16. education  (NEW — mig 398)
    --     Table: employee_education (multi-row, non-effective-dated)
    --     current: is_active=true rows only
    --     history: all rows including soft-deleted
    -- =========================================================================
    WHEN 'education' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              ee.education_level                         AS "Education Level Code *",
              ee.degree                                  AS "Degree *",
              ee.institution                             AS "Institution *",
              ee.field_of_study                          AS "Field of Study",
              TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
              TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
              ee.completion_status                        AS "Completion Status Code *",
              ee.grade_or_gpa                            AS "Grade / GPA",
              CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification",
              CASE WHEN ee.is_active THEN 'Yes' ELSE 'No' END                AS "Is Active"
            FROM   employee_education ee
            JOIN   employees e ON e.id = ee.employee_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, ee.is_active DESC,
                      ee.is_highest_qualification DESC,
                      ee.end_date DESC NULLS FIRST, ee.start_date DESC
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              ee.education_level                         AS "Education Level Code *",
              ee.degree                                  AS "Degree *",
              ee.institution                             AS "Institution *",
              ee.field_of_study                          AS "Field of Study",
              TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
              TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
              ee.completion_status                        AS "Completion Status Code *",
              ee.grade_or_gpa                            AS "Grade / GPA",
              CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification"
            FROM   employee_education ee
            JOIN   employees e ON e.id = ee.employee_id
            WHERE  ee.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id,
                      ee.is_highest_qualification DESC,
                      ee.end_date DESC NULLS FIRST, ee.start_date DESC
          ) r;
      END IF;

    ELSE
      RAISE EXCEPTION 'Unknown template_code: %. Check bulk_template_registry for valid codes.', p_template_code;

  END CASE;
END;
$$;

COMMENT ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) IS
  'Returns export rows as SETOF JSONB for the given template. '
  'Handles all 16 bulk templates (mig 398 added education as template 16). '
  'JSON keys match schema_definition column names. '
  'The Edge Function reads column order from the registry to write the CSV. '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL     ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT template_code, sort_order, processor_rpc
FROM   bulk_template_registry
WHERE  template_code = 'education';

SELECT routine_name
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'bulk_export';

-- =============================================================================
-- END OF MIGRATION 398
-- =============================================================================
