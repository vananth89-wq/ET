-- =============================================================================
-- Migration 411 — Bulk: system metadata for all 15 templates
--
-- PROBLEMS FIXED:
--
-- 1. PICKLIST — genuinely missing in mig 408 (comment said "already complete"
--    but it wasn't). The export query had no id/Created At/Updated At columns,
--    and Sort Order was silently dropped vs the mig 375 seed.
--    Fix: update bulk_export RPC WHEN 'picklist' clause + schema_definition.
--
-- 2. ALL TEMPLATES — mig 408's schema_definition UPDATEs used
--    jsonb_agg(col) without an ORDER BY inside the aggregate, relying on
--    subquery row order which PostgreSQL does not guarantee. This migration
--    re-applies every schema_definition using VALUES + jsonb_agg(col ORDER BY ord)
--    so the column sequence and include_with_system_metadata flags are reliable.
--
-- Idempotent: safe to run multiple times.
-- Predecessor: mig 408 (bulk_export RPC), mig 410 (department import fix)
-- =============================================================================


-- =============================================================================
-- PART 1 — Fix bulk_export WHEN 'picklist' clause (add Sort Order + sys meta)
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
        WHERE (p_include_inactive OR e.status<>'Inactive') ORDER BY e.employee_id) r;

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
        WHERE (p_include_inactive OR e.status<>'Inactive') ORDER BY e.employee_id) r;

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
        WHERE (p_include_inactive OR e.status<>'Inactive') ORDER BY e.employee_id) r;

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
          WHERE ee.is_active=true AND (p_include_inactive OR e.status<>'Inactive')
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
          WHERE s.is_active=true AND (p_include_inactive OR e.status<>'Inactive')
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
          WHERE s.is_active=true AND (p_include_inactive OR e.status<>'Inactive')
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
          WHERE s.is_active=true AND (p_include_inactive OR e.status<>'Inactive')
          ORDER BY e.employee_id, i.is_primary DESC, i.bank_name) r;
      END IF;

    -- =========================================================================
    -- 11. employees
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
    -- 12. department
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
    -- 13. picklist  (mig 411: restored Sort Order + added id/Created At/Updated At)
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
    -- 14. project
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
    -- 15. exchange_rate
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

    ELSE
      RAISE EXCEPTION 'Unknown template_code: %.', p_template_code;

  END CASE;
END;
$$;

COMMENT ON FUNCTION bulk_export IS
  'Mig 411: complete column coverage for all 15 templates. '
  'Picklist: restored Sort Order + added id/Created At/Updated At. '
  'System metadata (id, created_at, updated_at, etc.) filtered by Edge Function '
  'based on include_with_system_metadata flag in schema_definition.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 2 — Idempotent re-apply of all 15 schema_definitions
--
-- Uses VALUES(...) + jsonb_agg(col ORDER BY ord) — the ORDER BY is INSIDE the
-- aggregate, which PostgreSQL guarantees. This replaces the mig 408 pattern
-- of relying on subquery row order (not guaranteed by the SQL standard).
-- =============================================================================

-- 1. personal_info
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *',    'data_type','code_employee',           'mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Effective Date *',   'data_type','date_mmddyyyy',           'mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','First Name *',       'data_type','text',                    'mandatory',true, 'user_fillable',true),  3),
    (jsonb_build_object('name','Last Name *',        'data_type','text',                    'mandatory',true, 'user_fillable',true),  4),
    (jsonb_build_object('name','Middle Name',        'data_type','text',                    'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','Preferred Name',     'data_type','text',                    'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','Gender',             'data_type','text',                    'mandatory',false,'user_fillable',true),  7),
    (jsonb_build_object('name','Date of Birth',      'data_type','date_mmddyyyy',           'mandatory',false,'user_fillable',true),  8),
    (jsonb_build_object('name','Nationality (ISO3)', 'data_type','text',                    'mandatory',false,'user_fillable',true),  9),
    (jsonb_build_object('name','Marital Status',     'data_type','picklist:MARITAL_STATUS', 'mandatory',false,'user_fillable',true),  10),
    (jsonb_build_object('name','Slice End',          'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11),
    (jsonb_build_object('name','Slice Is Active',    'data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12),
    (jsonb_build_object('name','id',                 'data_type','uuid',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13),
    (jsonb_build_object('name','Created At',         'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 14),
    (jsonb_build_object('name','Updated At',         'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15),
    (jsonb_build_object('name','Inactive At',        'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *','Effective Date *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='personal_info';

-- 2. contact_info  (employee_contact uses employee_id as PK — no separate id column)
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *', 'data_type','code_employee','mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Personal Email',  'data_type','text',         'mandatory',false,'user_fillable',true),  2),
    (jsonb_build_object('name','Country Code',    'data_type','text',         'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Mobile',          'data_type','text',         'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='contact_info';

-- 3. address
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *', 'data_type','code_employee','mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Line 1',          'data_type','text',         'mandatory',false,'user_fillable',true),  2),
    (jsonb_build_object('name','Line 2',          'data_type','text',         'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Landmark',        'data_type','text',         'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','City',            'data_type','text',         'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','District',        'data_type','text',         'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','State',           'data_type','text',         'mandatory',false,'user_fillable',true),  7),
    (jsonb_build_object('name','Postal Code',     'data_type','text',         'mandatory',false,'user_fillable',true),  8),
    (jsonb_build_object('name','Country (ISO3)',  'data_type','text',         'mandatory',false,'user_fillable',true),  9),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='address';

-- 4. passport
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *',    'data_type','code_employee',      'mandatory',true, 'user_fillable',true), 1),
    (jsonb_build_object('name','Passport Number *',  'data_type','text',               'mandatory',true, 'user_fillable',true), 2),
    (jsonb_build_object('name','Country (ISO3)',     'data_type','picklist:ID_COUNTRY','mandatory',false,'user_fillable',true), 3),
    (jsonb_build_object('name','Issue Date',         'data_type','date_mmddyyyy',      'mandatory',false,'user_fillable',true), 4),
    (jsonb_build_object('name','Expiry Date',        'data_type','date_mmddyyyy',      'mandatory',false,'user_fillable',true), 5),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *','Passport Number *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='passport';

-- 5. identification
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *', 'data_type','code_employee',       'mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','ID Type *',       'data_type','picklist:ID_TYPE',    'mandatory',true, 'user_fillable',true,'description','ID type label or ref_id'),  2),
    (jsonb_build_object('name','ID Number *',     'data_type','text',                'mandatory',true, 'user_fillable',true),  3),
    (jsonb_build_object('name','Record Type',     'data_type','text',                'mandatory',false,'user_fillable',true,'description','e.g. National, Passport, Driver'),  4),
    (jsonb_build_object('name','Country (ISO3)',  'data_type','picklist:ID_COUNTRY', 'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','Expiry Date',     'data_type','date_mmddyyyy',       'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *','ID Type *','ID Number *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='identification';

-- 6. emergency_contact
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *',  'data_type','code_employee',             'mandatory',true, 'user_fillable',true), 1),
    (jsonb_build_object('name','Contact Name *',   'data_type','text',                      'mandatory',true, 'user_fillable',true), 2),
    (jsonb_build_object('name','Relationship',     'data_type','picklist:RELATIONSHIP_TYPE','mandatory',false,'user_fillable',true), 3),
    (jsonb_build_object('name','Phone',            'data_type','text',                      'mandatory',false,'user_fillable',true), 4),
    (jsonb_build_object('name','Alt Phone',        'data_type','text',                      'mandatory',false,'user_fillable',true), 5),
    (jsonb_build_object('name','Email',            'data_type','text',                      'mandatory',false,'user_fillable',true), 6),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='emergency_contact';

-- 7. employment
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Effective Date *',       'data_type','date_mmddyyyy',        'mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Employee Code *',        'data_type','code_employee',        'mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','Designation',            'data_type','picklist:DESIGNATION', 'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Job Title',              'data_type','text',                 'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Department Code',        'data_type','code_department',      'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','Manager Employee Code',  'data_type','code_employee',        'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','Hire Date',              'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true),  7),
    (jsonb_build_object('name','End Date',               'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true),  8),
    (jsonb_build_object('name','Work Country (ISO3)',    'data_type','picklist:WORK_COUNTRY','mandatory',false,'user_fillable',true),  9),
    (jsonb_build_object('name','Work Location',          'data_type','picklist:LOCATION',    'mandatory',false,'user_fillable',true),  10),
    (jsonb_build_object('name','Base Currency',          'data_type','text',                 'mandatory',false,'user_fillable',true),  11),
    (jsonb_build_object('name','Status',                 'data_type','text',                 'mandatory',false,'user_fillable',true),  12),
    (jsonb_build_object('name','Slice End',       'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13),
    (jsonb_build_object('name','Slice Is Active', 'data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 14),
    (jsonb_build_object('name','id',              'data_type','uuid',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15),
    (jsonb_build_object('name','Created At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16),
    (jsonb_build_object('name','Updated At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 17),
    (jsonb_build_object('name','Inactive At',     'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 18)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Effective Date *','Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='employment';

-- 8. job_relationships
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Effective Date *',     'data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Employee Code *',      'data_type','code_employee','mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','Relationship Code *',  'data_type','text',         'mandatory',true, 'user_fillable',true,'description','e.g. PM01, OM02'),  3),
    (jsonb_build_object('name','Value *',              'data_type','code_employee','mandatory',true, 'user_fillable',true,'description','Manager employee code'),  4),
    (jsonb_build_object('name','Slice End',       'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5),
    (jsonb_build_object('name','Slice Is Active', 'data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','id',              'data_type','uuid',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Created At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Updated At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Effective Date *','Employee Code *','Relationship Code *'),
  'row_processor', 'group_by_key'
), updated_at=NOW() WHERE template_code='job_relationships';

-- 9. dependents
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Effective Date *',   'data_type','date_mmddyyyy',                     'mandatory',true, 'user_fillable',true), 1),
    (jsonb_build_object('name','Employee Code *',    'data_type','code_employee',                     'mandatory',true, 'user_fillable',true), 2),
    (jsonb_build_object('name','Dependent Code *',   'data_type','text',                              'mandatory',true, 'user_fillable',true), 3),
    (jsonb_build_object('name','Dependent Name *',   'data_type','text',                              'mandatory',true, 'user_fillable',true), 4),
    (jsonb_build_object('name','Relationship *',     'data_type','picklist:DEPENDENT_RELATIONSHIP_TYPE','mandatory',true,'user_fillable',true), 5),
    (jsonb_build_object('name','Gender',             'data_type','text',                              'mandatory',false,'user_fillable',true,'description','Male or Female'), 6),
    (jsonb_build_object('name','Date of Birth',      'data_type','date_mmddyyyy',                     'mandatory',false,'user_fillable',true), 7),
    (jsonb_build_object('name','Insurance Eligible', 'data_type','yesno',                             'mandatory',false,'user_fillable',true,'description','Yes or No'), 8),
    (jsonb_build_object('name','Slice End',       'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9),
    (jsonb_build_object('name','Slice Is Active', 'data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10),
    (jsonb_build_object('name','id',              'data_type','uuid',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11),
    (jsonb_build_object('name','Created At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12),
    (jsonb_build_object('name','Updated At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Effective Date *','Employee Code *'),
  'row_processor', 'group_by_key'
), updated_at=NOW() WHERE template_code='dependents';

-- 10. bank_accounts
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Effective Date *',        'data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Employee Code *',         'data_type','code_employee','mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','Account Group Id *',      'data_type','text',         'mandatory',true, 'user_fillable',true),  3),
    (jsonb_build_object('name','Country (ISO3) *',        'data_type','text',         'mandatory',true, 'user_fillable',true),  4),
    (jsonb_build_object('name','Currency Code *',         'data_type','text',         'mandatory',true, 'user_fillable',true),  5),
    (jsonb_build_object('name','Bank Name *',             'data_type','text',         'mandatory',true, 'user_fillable',true),  6),
    (jsonb_build_object('name','Branch Name',             'data_type','text',         'mandatory',false,'user_fillable',true),  7),
    (jsonb_build_object('name','Branch Code',             'data_type','text',         'mandatory',false,'user_fillable',true),  8),
    (jsonb_build_object('name','Account Holder Name *',   'data_type','text',         'mandatory',true, 'user_fillable',true),  9),
    (jsonb_build_object('name','Account Number *',        'data_type','text',         'mandatory',true, 'user_fillable',true),  10),
    (jsonb_build_object('name','IFSC Code',               'data_type','text',         'mandatory',false,'user_fillable',true),  11),
    (jsonb_build_object('name','IBAN',                    'data_type','text',         'mandatory',false,'user_fillable',true),  12),
    (jsonb_build_object('name','SWIFT / BIC',             'data_type','text',         'mandatory',false,'user_fillable',true),  13),
    (jsonb_build_object('name','Is Primary',              'data_type','yesno',        'mandatory',false,'user_fillable',true),  14),
    (jsonb_build_object('name','Slice End',       'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15),
    (jsonb_build_object('name','Slice Is Active', 'data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16),
    (jsonb_build_object('name','id',              'data_type','uuid',         'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 17),
    (jsonb_build_object('name','Created At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 18),
    (jsonb_build_object('name','Updated At',      'data_type','timestamp',    'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 19)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Effective Date *','Employee Code *'),
  'row_processor', 'group_by_key'
), updated_at=NOW() WHERE template_code='bank_accounts';

-- 11. employees
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Employee Code *',       'data_type','code_employee',        'mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Full Name *',           'data_type','text',                 'mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','Business Email',        'data_type','text',                 'mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Designation',           'data_type','picklist:DESIGNATION', 'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Job Title',             'data_type','text',                 'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','Department Code',       'data_type','code_department',      'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','Manager Employee Code', 'data_type','code_employee',        'mandatory',false,'user_fillable',true),  7),
    (jsonb_build_object('name','Hire Date',             'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true),  8),
    (jsonb_build_object('name','End Date',              'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true),  9),
    (jsonb_build_object('name','Work Country (ISO3)',   'data_type','picklist:WORK_COUNTRY','mandatory',false,'user_fillable',true),  10),
    (jsonb_build_object('name','Work Location',         'data_type','picklist:LOCATION',    'mandatory',false,'user_fillable',true),  11),
    (jsonb_build_object('name','Base Currency',         'data_type','text',                 'mandatory',false,'user_fillable',true),  12),
    (jsonb_build_object('name','Status',                'data_type','text',                 'mandatory',false,'user_fillable',true),  13),
    (jsonb_build_object('name','PM01 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Project Manager'),     14),
    (jsonb_build_object('name','PM02 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Programme Manager'),   15),
    (jsonb_build_object('name','PM03 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Practice Manager'),    16),
    (jsonb_build_object('name','OM01 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Manager'),  17),
    (jsonb_build_object('name','OM02 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Lead'),     18),
    (jsonb_build_object('name','OM03 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Coordinator'), 19),
    (jsonb_build_object('name','id',                 'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 20),
    (jsonb_build_object('name','Submitted At',       'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 21),
    (jsonb_build_object('name','Invite Sent At',     'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 22),
    (jsonb_build_object('name','Invite Accepted At', 'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 23),
    (jsonb_build_object('name','Locked',             'data_type','boolean',  'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 24),
    (jsonb_build_object('name','Created By',         'data_type','text',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 25),
    (jsonb_build_object('name','Created At',         'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 26),
    (jsonb_build_object('name','Updated At',         'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 27),
    (jsonb_build_object('name','Deleted At',         'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 28)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Employee Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='employees';

-- 12. department  (also fixed in mig 410; this is the same idempotent re-apply)
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Department Code *',      'data_type','text',           'mandatory',true, 'user_fillable',true),  1),
    (jsonb_build_object('name','Department Name *',      'data_type','text',           'mandatory',true, 'user_fillable',true),  2),
    (jsonb_build_object('name','Parent Department Code', 'data_type','code_department','mandatory',false,'user_fillable',true),  3),
    (jsonb_build_object('name','Head Employee Code',     'data_type','code_employee',  'mandatory',false,'user_fillable',true),  4),
    (jsonb_build_object('name','Start Date',             'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true),  5),
    (jsonb_build_object('name','End Date',               'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Department Code *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='department';

-- 13. picklist  (mig 411: first time system metadata is added for this template)
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Picklist Id *',      'data_type','text',   'mandatory',true, 'user_fillable',true,'description','The picklist identifier, e.g. ID_COUNTRY'), 1),
    (jsonb_build_object('name','Ref Id *',           'data_type','text',   'mandatory',true, 'user_fillable',true,'description','Short code uniquely identifying this value, e.g. IND'), 2),
    (jsonb_build_object('name','Value *',            'data_type','text',   'mandatory',true, 'user_fillable',true,'description','Display label, e.g. India'), 3),
    (jsonb_build_object('name','Parent Picklist Id', 'data_type','text',   'mandatory',false,'user_fillable',true,'description','For cascading values: the parent picklist identifier'), 4),
    (jsonb_build_object('name','Parent Ref Id',      'data_type','text',   'mandatory',false,'user_fillable',true,'description','For cascading values: the ref_id of the parent value'), 5),
    (jsonb_build_object('name','Sort Order',         'data_type','integer','mandatory',false,'user_fillable',true),  6),
    (jsonb_build_object('name','Active',             'data_type','yesno',  'mandatory',false,'user_fillable',true,'description','Yes (default) or No to deactivate'),  7),
    (jsonb_build_object('name','Meta',               'data_type','text',   'mandatory',false,'user_fillable',true,'description','Optional JSON metadata. Must be valid JSON if provided.'),  8),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Picklist Id *','Ref Id *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='picklist';

-- 14. project
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Project Name *','data_type','text',        'mandatory',true, 'user_fillable',true,'description','Project name — natural key. Changing it creates a new project.'), 1),
    (jsonb_build_object('name','Start Date',    'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 2),
    (jsonb_build_object('name','End Date',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 3),
    (jsonb_build_object('name','Active',        'data_type','yesno',       'mandatory',false,'user_fillable',true,'description','Yes (default) or No to deactivate'), 4),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Project Name *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='project';

-- 15. exchange_rate
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','From Currency *',   'data_type','code_currency',  'mandatory',true,'user_fillable',true,'description','Source currency code, e.g. INR, USD'), 1),
    (jsonb_build_object('name','To Currency *',     'data_type','code_currency',  'mandatory',true,'user_fillable',true,'description','Target currency code, e.g. USD, GBP'), 2),
    (jsonb_build_object('name','Effective Date *',  'data_type','date_mmddyyyy',  'mandatory',true,'user_fillable',true,'description','Date from which this rate applies'), 3),
    (jsonb_build_object('name','Rate *',            'data_type','text',           'mandatory',true,'user_fillable',true,'description','Decimal rate, e.g. 0.012000'), 4),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('From Currency *','To Currency *','Effective Date *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='exchange_rate';


-- =============================================================================
-- Verification — the 15 templates updated by this migration must all have
-- landed. Education (and any future templates) are intentionally excluded.
-- =============================================================================
DO $$
DECLARE
  v_missing TEXT;
  -- The exact 15 template_codes this migration touches
  v_codes   TEXT[] := ARRAY[
    'personal_info','contact_info','address','passport','identification',
    'emergency_contact','employment','job_relationships','dependents',
    'bank_accounts','employees','department','picklist','project','exchange_rate'
  ];
BEGIN
  -- 1. All 15 must have been updated within the last minute
  SELECT string_agg(template_code, ', ' ORDER BY sort_order)
  INTO   v_missing
  FROM   bulk_template_registry
  WHERE  template_code = ANY(v_codes)
    AND  updated_at < NOW() - INTERVAL '1 minute';

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'schema_definition UPDATE missed templates: %', v_missing;
  END IF;

  -- 2. All 15 must have at least one include_with_system_metadata column
  SELECT string_agg(template_code, ', ' ORDER BY sort_order)
  INTO   v_missing
  FROM   bulk_template_registry
  WHERE  template_code = ANY(v_codes)
    AND  NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(schema_definition->'columns') col
      WHERE (col->>'include_with_system_metadata')::boolean = true
    );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Templates still missing include_with_system_metadata columns: %', v_missing;
  END IF;
END $$;

-- =============================================================================
-- END OF MIGRATION 411
-- =============================================================================
