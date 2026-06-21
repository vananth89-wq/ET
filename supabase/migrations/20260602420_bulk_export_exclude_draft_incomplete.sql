-- =============================================================================
-- Migration 417 — bulk_export: exclude Draft/Incomplete employees from all
--                 employee-scoped templates
--
-- PROBLEM: Only the 'employees' template had AND e.status NOT IN ('Draft','Incomplete').
-- All 12 other employee-scoped templates omitted this guard, so education, employment,
-- personal_info, etc. could return records for employees still in the hire wizard.
-- Draft/Incomplete employees don't appear in the employees master export, so their
-- rows in other templates are not round-trip safe.
--
-- FIX: Add the guard to all 12 employee-scoped templates (both current + history modes
-- where applicable). Non-employee templates (department, picklist, project,
-- exchange_rate) are unchanged.
--
-- Templates fixed (previously missing guard):
--   1. personal_info   2. contact_info    3. address         4. passport
--   5. identification  6. emergency_contact  7. employment   8. job_relationships
--   9. dependents      10. bank_accounts  16. education
-- Template already correct:
--   11. employees (had AND e.status NOT IN ('Draft','Incomplete') since mig 408)
-- Not applicable (no employee join):
--   12. department  13. picklist  14. project  15. exchange_rate
--
-- Predecessor: mig 416 (education field_of_study fix)
-- =============================================================================

CREATE OR REPLACE FUNCTION bulk_export(
  p_template_code    TEXT,
  p_include_inactive BOOLEAN DEFAULT false,
  p_mode             TEXT    DEFAULT 'current'
)
RETURNS SETOF JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT user_can(p_template_code, 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_export required', p_template_code USING ERRCODE = '42501';
  END IF;

  CASE p_template_code

    -- =========================================================================
    -- 1. personal_info
    -- =========================================================================
    WHEN 'personal_info' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                            AS "Employee Code *",
            TO_CHAR(ep.effective_from,'MM/DD/YYYY')                                  AS "Effective Date *",
            TO_CHAR(ep.effective_to,  'MM/DD/YYYY')                                  AS "Slice End",
            ep.is_active                                                              AS "Slice Is Active",
            ep.first_name                                                             AS "First Name *",
            ep.last_name                                                              AS "Last Name *",
            ep.middle_name                                                            AS "Middle Name",
            ep.preferred_name                                                         AS "Preferred Name",
            ep.gender                                                                 AS "Gender",
            TO_CHAR(ep.dob,'MM/DD/YYYY')                                              AS "Date of Birth",
            ep.nationality                                                            AS "Nationality (ISO3)",
            COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),ep.marital_status) AS "Marital Status",
            ep.id::text                                                               AS "id",
            TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI')                              AS "Created At",
            TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI')                              AS "Updated At",
            TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI')                             AS "Inactive At"
          FROM employee_personal ep JOIN employees e ON e.id=ep.employee_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, ep.effective_from) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                            AS "Employee Code *",
            TO_CHAR(ep.effective_from,'MM/DD/YYYY')                                  AS "Effective Date *",
            ep.first_name                                                             AS "First Name *",
            ep.last_name                                                              AS "Last Name *",
            ep.middle_name                                                            AS "Middle Name",
            ep.preferred_name                                                         AS "Preferred Name",
            ep.gender                                                                 AS "Gender",
            TO_CHAR(ep.dob,'MM/DD/YYYY')                                              AS "Date of Birth",
            ep.nationality                                                            AS "Nationality (ISO3)",
            COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),ep.marital_status) AS "Marital Status",
            ep.id::text                                                               AS "id",
            TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI')                              AS "Created At",
            TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI')                              AS "Updated At",
            TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI')                             AS "Inactive At"
          FROM employee_personal ep JOIN employees e ON e.id=ep.employee_id
          WHERE ep.is_active=true AND ep.effective_to='9999-12-31'::date
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id) r;
      END IF;

    -- =========================================================================
    -- 2. contact_info
    -- =========================================================================
    WHEN 'contact_info' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                               AS "Employee Code *",
          ec.personal_email                           AS "Personal Email",
          ec.country_code                             AS "Country Code",
          ec.mobile                                   AS "Mobile",
          TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
          TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
        FROM employee_contact ec JOIN employees e ON e.id=ec.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 3. address
    -- =========================================================================
    WHEN 'address' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                                AS "Employee Code *",
          ea.line1                                     AS "Line 1",
          ea.line2                                     AS "Line 2",
          ea.landmark                                  AS "Landmark",
          ea.city                                      AS "City",
          ea.district                                  AS "District",
          ea.state                                     AS "State",
          ea.pin                                       AS "Postal Code",
          ea.country                                   AS "Country (ISO3)",
          ea.id::text                                  AS "id",
          TO_CHAR(ea.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(ea.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM employee_addresses ea JOIN employees e ON e.id=ea.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 4. passport
    -- =========================================================================
    WHEN 'passport' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                                AS "Employee Code *",
          p.passport_number                            AS "Passport Number *",
          COALESCE(picklist_label('ID_COUNTRY',p.country),p.country) AS "Country (ISO3)",
          TO_CHAR(p.issue_date, 'MM/DD/YYYY')          AS "Issue Date",
          TO_CHAR(p.expiry_date,'MM/DD/YYYY')          AS "Expiry Date",
          p.id::text                                   AS "id",
          TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
          TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
        FROM passports p JOIN employees e ON e.id=p.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 5. identification
    -- =========================================================================
    WHEN 'identification' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                                AS "Employee Code *",
          COALESCE(picklist_label('ID_TYPE',ir.id_type),ir.id_type)    AS "ID Type *",
          ir.id_number                                 AS "ID Number *",
          ir.record_type                               AS "Record Type",
          COALESCE(picklist_label('ID_COUNTRY',ir.country),ir.country) AS "Country (ISO3)",
          TO_CHAR(ir.expiry,'MM/DD/YYYY')              AS "Expiry Date",
          ir.id::text                                  AS "id",
          TO_CHAR(ir.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(ir.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM identity_records ir JOIN employees e ON e.id=ir.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id, ir.id_type) r;

    -- =========================================================================
    -- 6. emergency_contact
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                                AS "Employee Code *",
          ec.name                                      AS "Contact Name *",
          COALESCE(picklist_label('RELATIONSHIP_TYPE',ec.relationship),ec.relationship) AS "Relationship",
          ec.phone                                     AS "Phone",
          ec.alt_phone                                 AS "Alt Phone",
          ec.email                                     AS "Email",
          ec.id::text                                  AS "id",
          TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM emergency_contacts ec JOIN employees e ON e.id=ec.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id, ec.created_at) r;

    -- =========================================================================
    -- 7. employment
    -- =========================================================================
    WHEN 'employment' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                              AS "Employee Code *",
            TO_CHAR(ee.effective_from,'MM/DD/YYYY')                                    AS "Effective Date *",
            TO_CHAR(ee.effective_to,  'MM/DD/YYYY')                                    AS "Slice End",
            ee.is_active                                                               AS "Slice Is Active",
            COALESCE(picklist_label('DESIGNATION',ee.designation),ee.designation)      AS "Designation",
            ee.job_title                                                               AS "Job Title",
            d.dept_id                                                                  AS "Department Code",
            mgr.employee_id                                                            AS "Manager Employee Code",
            TO_CHAR(ee.hire_date,'MM/DD/YYYY')                                         AS "Hire Date",
            TO_CHAR(ee.end_date, 'MM/DD/YYYY')                                         AS "End Date",
            COALESCE(picklist_value_label(ee.work_country),ee.work_country)            AS "Work Country (ISO3)",
            COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location)     AS "Work Location",
            c.code                                                                     AS "Base Currency",
            ee.status::text                                                            AS "Status",
            ee.id::text                                                                AS "id",
            TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI')                               AS "Created At",
            TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI')                               AS "Updated At",
            TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI')                               AS "Inactive At"
          FROM employee_employment ee JOIN employees e ON e.id=ee.employee_id
          LEFT JOIN departments d  ON d.id=ee.dept_id
          LEFT JOIN employees mgr  ON mgr.id=ee.manager_id
          LEFT JOIN currencies c   ON c.id=ee.base_currency_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, ee.effective_from) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                              AS "Employee Code *",
            TO_CHAR(ee.effective_from,'MM/DD/YYYY')                                    AS "Effective Date *",
            COALESCE(picklist_label('DESIGNATION',ee.designation),ee.designation)      AS "Designation",
            ee.job_title                                                               AS "Job Title",
            d.dept_id                                                                  AS "Department Code",
            mgr.employee_id                                                            AS "Manager Employee Code",
            TO_CHAR(ee.hire_date,'MM/DD/YYYY')                                         AS "Hire Date",
            TO_CHAR(ee.end_date, 'MM/DD/YYYY')                                         AS "End Date",
            COALESCE(picklist_value_label(ee.work_country),ee.work_country)            AS "Work Country (ISO3)",
            COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location)     AS "Work Location",
            c.code                                                                     AS "Base Currency",
            ee.status::text                                                            AS "Status",
            ee.id::text                                                                AS "id",
            TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI')                               AS "Created At",
            TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI')                               AS "Updated At",
            TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI')                               AS "Inactive At"
          FROM employee_employment ee JOIN employees e ON e.id=ee.employee_id
          LEFT JOIN departments d  ON d.id=ee.dept_id
          LEFT JOIN employees mgr  ON mgr.id=ee.manager_id
          LEFT JOIN currencies c   ON c.id=ee.base_currency_id
          WHERE ee.is_active=true
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id) r;
      END IF;

    -- =========================================================================
    -- 8. job_relationships
    -- =========================================================================
    WHEN 'job_relationships' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            TO_CHAR(s.effective_to,  'MM/DD/YYYY')       AS "Slice End",
            s.is_active                                  AS "Slice Is Active",
            i.relationship_code                          AS "Relationship Code *",
            mgr.employee_id                              AS "Value *",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_job_relationship_set s
          JOIN employee_job_relationship_item i ON i.set_id=s.id
          JOIN employees e   ON e.id=s.employee_id
          JOIN employees mgr ON mgr.id=i.manager_employee_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, s.effective_from, i.relationship_code) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            i.relationship_code                          AS "Relationship Code *",
            mgr.employee_id                              AS "Value *",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_job_relationship_set s
          JOIN employee_job_relationship_item i ON i.set_id=s.id
          JOIN employees e   ON e.id=s.employee_id
          JOIN employees mgr ON mgr.id=i.manager_employee_id
          WHERE s.is_active=true
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, i.relationship_code) r;
      END IF;

    -- =========================================================================
    -- 9. dependents
    -- =========================================================================
    WHEN 'dependents' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            TO_CHAR(s.effective_to,  'MM/DD/YYYY')       AS "Slice End",
            s.is_active                                  AS "Slice Is Active",
            i.dependent_code                             AS "Dependent Code *",
            i.dependent_name                             AS "Dependent Name *",
            COALESCE(
              (SELECT pv.value FROM picklist_values pv
               JOIN picklists pl ON pl.id=pv.picklist_id
               WHERE pl.picklist_id='DEPENDENT_RELATIONSHIP_TYPE'
                 AND lower(pv.ref_id)=lower(i.relationship_type)
                 AND pv.active=true LIMIT 1),
              i.relationship_type)                       AS "Relationship *",
            i.gender                                     AS "Gender",
            TO_CHAR(i.date_of_birth,'MM/DD/YYYY')        AS "Date of Birth",
            CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_dependent_set s
          JOIN employee_dependent_item i ON i.set_id=s.id
          JOIN employees e ON e.id=s.employee_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, s.effective_from, i.dependent_code) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            i.dependent_code                             AS "Dependent Code *",
            i.dependent_name                             AS "Dependent Name *",
            COALESCE(
              (SELECT pv.value FROM picklist_values pv
               JOIN picklists pl ON pl.id=pv.picklist_id
               WHERE pl.picklist_id='DEPENDENT_RELATIONSHIP_TYPE'
                 AND lower(pv.ref_id)=lower(i.relationship_type)
                 AND pv.active=true LIMIT 1),
              i.relationship_type)                       AS "Relationship *",
            i.gender                                     AS "Gender",
            TO_CHAR(i.date_of_birth,'MM/DD/YYYY')        AS "Date of Birth",
            CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_dependent_set s
          JOIN employee_dependent_item i ON i.set_id=s.id
          JOIN employees e ON e.id=s.employee_id
          WHERE s.is_active=true
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, i.dependent_code) r;
      END IF;

    -- =========================================================================
    -- 10. bank_accounts
    -- =========================================================================
    WHEN 'bank_accounts' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            TO_CHAR(s.effective_to,  'MM/DD/YYYY')       AS "Slice End",
            s.is_active                                  AS "Slice Is Active",
            i.bank_account_group_id::text                AS "Account Group Id *",
            i.country_code                               AS "Country (ISO3) *",
            i.currency_code                              AS "Currency Code *",
            i.bank_name                                  AS "Bank Name *",
            i.branch_name                                AS "Branch Name",
            i.branch_code                                AS "Branch Code",
            i.account_holder_name                        AS "Account Holder Name *",
            i.account_number                             AS "Account Number *",
            i.ifsc_code                                  AS "IFSC Code",
            i.iban                                       AS "IBAN",
            i.swift_bic                                  AS "SWIFT / BIC",
            CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_bank_account_set s
          JOIN employee_bank_account_item i ON i.set_id=s.id
          JOIN employees e ON e.id=s.employee_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, s.effective_from, i.bank_name) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            TO_CHAR(s.effective_from,'MM/DD/YYYY')       AS "Effective Date *",
            i.bank_account_group_id::text                AS "Account Group Id *",
            i.country_code                               AS "Country (ISO3) *",
            i.currency_code                              AS "Currency Code *",
            i.bank_name                                  AS "Bank Name *",
            i.branch_name                                AS "Branch Name",
            i.branch_code                                AS "Branch Code",
            i.account_holder_name                        AS "Account Holder Name *",
            i.account_number                             AS "Account Number *",
            i.ifsc_code                                  AS "IFSC Code",
            i.iban                                       AS "IBAN",
            i.swift_bic                                  AS "SWIFT / BIC",
            CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
            s.id::text                                   AS "id",
            TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
            TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
          FROM employee_bank_account_set s
          JOIN employee_bank_account_item i ON i.set_id=s.id
          JOIN employees e ON e.id=s.employee_id
          WHERE s.is_active=true
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, i.is_primary DESC, i.bank_name) r;
      END IF;

    -- =========================================================================
    -- 11. employees  (guard was already present; unchanged)
    -- =========================================================================
    WHEN 'employees' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                                                            AS "Employee Code *",
          e.name                                                                   AS "Full Name *",
          e.business_email                                                         AS "Business Email",
          COALESCE(picklist_label('DESIGNATION',e.designation),e.designation)      AS "Designation",
          e.job_title                                                              AS "Job Title",
          d.dept_id                                                                AS "Department Code",
          mgr.employee_id                                                          AS "Manager Employee Code",
          TO_CHAR(e.hire_date,'MM/DD/YYYY')                                        AS "Hire Date",
          TO_CHAR(e.end_date, 'MM/DD/YYYY')                                        AS "End Date",
          COALESCE(picklist_value_label(e.work_country),e.work_country)            AS "Work Country (ISO3)",
          COALESCE(picklist_label('LOCATION',e.work_location),e.work_location)     AS "Work Location",
          c.code                                                                   AS "Base Currency",
          e.status::text                                                           AS "Status",
          pm01.employee_id                                                         AS "PM01 Manager",
          pm02.employee_id                                                         AS "PM02 Manager",
          pm03.employee_id                                                         AS "PM03 Manager",
          om01.employee_id                                                         AS "OM01 Manager",
          om02.employee_id                                                         AS "OM02 Manager",
          om03.employee_id                                                         AS "OM03 Manager",
          e.id::text                                                               AS "id",
          TO_CHAR(e.submitted_at,       'MM/DD/YYYY HH24:MI')                     AS "Submitted At",
          TO_CHAR(e.invite_sent_at,     'MM/DD/YYYY HH24:MI')                     AS "Invite Sent At",
          TO_CHAR(e.invite_accepted_at, 'MM/DD/YYYY HH24:MI')                     AS "Invite Accepted At",
          CASE WHEN e.locked THEN 'Yes' ELSE 'No' END                             AS "Locked",
          e_creator.name                                                           AS "Created By",
          TO_CHAR(e.created_at,'MM/DD/YYYY HH24:MI')                              AS "Created At",
          TO_CHAR(e.updated_at,'MM/DD/YYYY HH24:MI')                              AS "Updated At",
          TO_CHAR(e.deleted_at,'MM/DD/YYYY HH24:MI')                              AS "Deleted At"
        FROM employees e
        LEFT JOIN departments d    ON d.id    = e.dept_id
        LEFT JOIN employees   mgr  ON mgr.id  = e.manager_id
        LEFT JOIN currencies  c    ON c.id    = e.base_currency_id
        LEFT JOIN employees   pm01 ON pm01.id = e.pm01_manager_id
        LEFT JOIN employees   pm02 ON pm02.id = e.pm02_manager_id
        LEFT JOIN employees   pm03 ON pm03.id = e.pm03_manager_id
        LEFT JOIN employees   om01 ON om01.id = e.om01_manager_id
        LEFT JOIN employees   om02 ON om02.id = e.om02_manager_id
        LEFT JOIN employees   om03      ON om03.id      = e.om03_manager_id
        LEFT JOIN profiles    p_creator ON p_creator.id = e.created_by
        LEFT JOIN employees   e_creator ON e_creator.id = p_creator.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
          AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 12. department  (not employee-scoped — no change)
    -- =========================================================================
    WHEN 'department' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          d.dept_id                                    AS "Department Code *",
          d.name                                       AS "Department Name *",
          pd.dept_id                                   AS "Parent Department Code",
          hd.employee_id                               AS "Head Employee Code",
          TO_CHAR(d.start_date,'MM/DD/YYYY')           AS "Start Date",
          TO_CHAR(d.end_date,  'MM/DD/YYYY')           AS "End Date",
          d.id::text                                   AS "id",
          TO_CHAR(d.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
          TO_CHAR(d.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
        FROM departments d
        LEFT JOIN departments pd ON pd.id = d.parent_dept_id
        LEFT JOIN employees   hd ON hd.id = d.head_employee_id
        WHERE d.deleted_at IS NULL
        ORDER BY d.dept_id) r;

    -- =========================================================================
    -- 13. picklist  (not employee-scoped — no change)
    -- =========================================================================
    WHEN 'picklist' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          pl.id::text                                  AS "Picklist Id *",
          pv.ref_id                                    AS "Ref Id *",
          pv.value                                     AS "Value *",
          parent_pl.id::text                           AS "Parent Picklist Id",
          parent_pv.ref_id                             AS "Parent Ref Id",
          pv.sort_order::text                          AS "Sort Order",
          CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
          pv.meta::text                                AS "Meta",
          pv.id::text                                  AS "id",
          TO_CHAR(pv.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(pv.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM picklist_values pv
        JOIN picklists pl ON pl.id=pv.picklist_id
        LEFT JOIN picklist_values parent_pv ON parent_pv.id=pv.parent_value_id
        LEFT JOIN picklists parent_pl ON parent_pl.id=parent_pv.picklist_id
        WHERE (p_include_inactive OR pv.active=true)
        ORDER BY pl.id, pv.sort_order, pv.ref_id) r;

    -- =========================================================================
    -- 14. project  (not employee-scoped — no change)
    -- =========================================================================
    WHEN 'project' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          p.name                                       AS "Project Name *",
          TO_CHAR(p.start_date,'MM/DD/YYYY')           AS "Start Date",
          TO_CHAR(p.end_date,  'MM/DD/YYYY')           AS "End Date",
          CASE WHEN p.active THEN 'Yes' ELSE 'No' END  AS "Active",
          p.id::text                                   AS "id",
          TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI')   AS "Created At",
          TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI')   AS "Updated At"
        FROM projects p WHERE (p_include_inactive OR p.active=true) ORDER BY p.name) r;

    -- =========================================================================
    -- 15. exchange_rate  (not employee-scoped — no change)
    -- =========================================================================
    WHEN 'exchange_rate' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          fc.code                                      AS "From Currency *",
          tc.code                                      AS "To Currency *",
          TO_CHAR(er.effective_date,'MM/DD/YYYY')      AS "Effective Date *",
          er.rate::text                                AS "Rate *",
          er.id::text                                  AS "id",
          TO_CHAR(er.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(er.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM exchange_rates er
        JOIN currencies fc ON fc.id=er.from_currency_id
        JOIN currencies tc ON tc.id=er.to_currency_id
        ORDER BY fc.code, tc.code, er.effective_date) r;

    -- =========================================================================
    -- 16. education
    -- =========================================================================
    WHEN 'education' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                            AS "Employee Code *",
            ee.education_level                                                       AS "Education Level Code *",
            ee.degree                                                                AS "Degree *",
            ee.institution                                                           AS "Institution *",
            TO_CHAR(ee.start_date,'MM/DD/YYYY')                                      AS "Start Date *",
            TO_CHAR(ee.end_date,  'MM/DD/YYYY')                                      AS "End Date",
            ee.completion_status                                                     AS "Completion Status Code *",
            ee.grade_or_gpa                                                          AS "Grade / GPA",
            CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END          AS "Highest Qualification",
            CASE WHEN ee.is_active THEN 'Yes' ELSE 'No' END                         AS "Is Active",
            ee.id::text                                                              AS "id",
            TO_CHAR(ee.created_at,'MM/DD/YYYY HH24:MI')                             AS "Created At",
            TO_CHAR(ee.updated_at,'MM/DD/YYYY HH24:MI')                             AS "Updated At"
          FROM employee_education ee
          JOIN employees e ON e.id=ee.employee_id
          WHERE (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id, ee.is_active DESC,
                   ee.is_highest_qualification DESC,
                   ee.end_date DESC NULLS FIRST, ee.start_date DESC) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                            AS "Employee Code *",
            ee.education_level                                                       AS "Education Level Code *",
            ee.degree                                                                AS "Degree *",
            ee.institution                                                           AS "Institution *",
            TO_CHAR(ee.start_date,'MM/DD/YYYY')                                      AS "Start Date *",
            TO_CHAR(ee.end_date,  'MM/DD/YYYY')                                      AS "End Date",
            ee.completion_status                                                     AS "Completion Status Code *",
            ee.grade_or_gpa                                                          AS "Grade / GPA",
            CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END          AS "Highest Qualification",
            ee.id::text                                                              AS "id",
            TO_CHAR(ee.created_at,'MM/DD/YYYY HH24:MI')                             AS "Created At",
            TO_CHAR(ee.updated_at,'MM/DD/YYYY HH24:MI')                             AS "Updated At"
          FROM employee_education ee
          JOIN employees e ON e.id=ee.employee_id
          WHERE ee.is_active=true
            AND (p_include_inactive OR e.status<>'Inactive')
            AND e.status NOT IN ('Draft','Incomplete')
          ORDER BY e.employee_id,
                   ee.is_highest_qualification DESC,
                   ee.end_date DESC NULLS FIRST, ee.start_date DESC) r;
      END IF;

    ELSE
      RAISE EXCEPTION 'Unknown template_code: %.', p_template_code;

  END CASE;
END;
$$;

COMMENT ON FUNCTION bulk_export IS
  'Mig 417: all 16 templates. Draft/Incomplete employees excluded from all '
  'employee-scoped templates (1–11, 16). Non-employee templates unchanged.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 417
-- =============================================================================
