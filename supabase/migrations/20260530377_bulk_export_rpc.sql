-- =============================================================================
-- Migration 377 — Bulk Operations Framework: bulk_export RPC
--
-- Single SECURITY DEFINER function that handles CSV export for all 15 templates.
-- Returns SETOF JSONB — each row is a JSON object whose keys match the
-- schema_definition column names. The Edge Function reads schema_definition
-- to determine column order and writes the CSV header + rows.
--
-- Design decision (locked):
--   The registry's exporter_query column documents the SQL shape.
--   It is NOT executed dynamically (SQL injection risk). The actual SQL
--   lives here in hardcoded WHEN clauses.
--
-- Auth: per-template user_can(<template_code>, 'bulk_export', NULL) enforced
--       at the top of each WHEN clause so no template bleeds into another.
--
-- Parameters:
--   p_template_code    — must match a bulk_template_registry.template_code
--   p_include_inactive — include records for inactive employees / inactive rows
--   p_mode             — 'current' (default, round-trip-safe) | 'history' (audit)
--
-- Predecessor: mig 376 (processor RPC wrappers)
-- Design spec: docs/bulk-operations-framework.md §10
-- =============================================================================

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
  -- Single permission gate covers all templates.
  -- user_can(module, action, target) looks for permission code = module || '.' || action.
  -- template_code matches the permission code prefix for all 15 templates.
  IF NOT user_can(p_template_code, 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_export required', p_template_code
      USING ERRCODE = '42501';
  END IF;

  CASE p_template_code

    -- =========================================================================
    -- 1. personal_info
    --    Table: employee_personal (employee_id PK FK)
    --    Columns: first_name, last_name, middle_name, gender, dob,
    --             nationality, marital_status
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
    --    Table: employee_contact (employee_id PK FK)
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
    --    Table: employee_addresses (employee_id UNIQUE FK)
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
    --    Table: passports (employee_id UNIQUE FK)
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
    --    Table: identity_records (employee_id FK — multiple per employee)
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
    --    Table: emergency_contacts (employee_id FK)
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
    --    Table: employee_employment (effective-dated, mig 351)
    --    current mode: active slice only (is_active = true)
    --    history mode: all slices
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
    --    Tables: employee_job_relationship_set + employee_job_relationship_item
    --    current: active set only; history: all sets
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
    --    Tables: employee_dependent_set + employee_dependent_item
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
    --     Tables: employee_bank_account_set + employee_bank_account_item
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
    --     Table: employees
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
    --     Table: departments
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
    --     Tables: picklists + picklist_values
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
    --     Table: projects
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
    --     Table: exchange_rates
    --     Joined to currencies for codes. All rows are timeline (no inactive concept).
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

    ELSE
      RAISE EXCEPTION 'Unknown template_code: %. Check bulk_template_registry for valid codes.', p_template_code;

  END CASE;
END;
$$;

COMMENT ON FUNCTION bulk_export IS
  'Returns export rows as SETOF JSONB for the given template. '
  'Handles all 15 bulk templates. JSON keys match schema_definition column names. '
  'The Edge Function reads column order from the registry to write the CSV. '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- Verification
-- =============================================================================

SELECT routine_name, routine_type, security_type
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name = 'bulk_export';

-- =============================================================================
-- END OF MIGRATION 377
-- =============================================================================
