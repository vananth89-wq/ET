-- =============================================================================
-- Migration 423 — bulk_export: dispatch table pattern
--
-- PROBLEM: bulk_export is a ~400-line monolith. Every new template or fix
-- requires replacing the entire function body, risking accidental clause
-- drops (we've had 6 such migrations). Called the "snowball function" problem.
--
-- SOLUTION: Dispatch table pattern.
--   • Each template owns a small private _bulk_export_{code}() function.
--   • The public bulk_export() dispatcher is a stable ~25-line router that
--     NEVER needs to change when a template is added or modified.
--   • Adding a new template = one new _bulk_export_* function + nothing else.
--   • Modifying a template = replace only that template's function.
--
-- ZERO BREAKING CHANGES:
--   • Public signature bulk_export(TEXT, BOOLEAN, TEXT) is identical.
--   • Edge Function calls it the same way.
--   • No frontend changes.
--
-- SECURITY: Dynamic dispatch uses %I (identifier quoting) after validating
--   the template_code against bulk_template_registry — SQL injection is
--   impossible since only registered codes can pass the EXISTS check.
--
-- All 16 per-template functions are exact copies of the clauses from mig 420.
-- Predecessor: mig 422 (bulk_diff_preview RPC)
-- =============================================================================


-- =============================================================================
-- PART 1 — Per-template private export functions
-- =============================================================================

-- 1. personal_info ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_personal_info(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ep.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(ep.effective_to,  'MM/DD/YYYY') AS "Slice End",
        ep.is_active AS "Slice Is Active",
        ep.first_name AS "First Name *", ep.last_name AS "Last Name *",
        ep.middle_name AS "Middle Name", ep.preferred_name AS "Preferred Name",
        ep.gender AS "Gender", TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),ep.marital_status) AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep JOIN employees e ON e.id=ep.employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ep.effective_from) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ep.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        ep.first_name AS "First Name *", ep.last_name AS "Last Name *",
        ep.middle_name AS "Middle Name", ep.preferred_name AS "Preferred Name",
        ep.gender AS "Gender", TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),ep.marital_status) AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep JOIN employees e ON e.id=ep.employee_id
      WHERE ep.is_active=true AND ep.effective_to='9999-12-31'::date
        AND (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

-- 2. contact_info ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_contact_info(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ec.personal_email AS "Personal Email", ec.country_code AS "Country Code", ec.mobile AS "Mobile",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM employee_contact ec JOIN employees e ON e.id=ec.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

-- 3. address ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_address(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ea.line1 AS "Line 1", ea.line2 AS "Line 2", ea.landmark AS "Landmark",
      ea.city AS "City", ea.district AS "District", ea.state AS "State",
      ea.pin AS "Postal Code", ea.country AS "Country (ISO3)",
      ea.id::text AS "id",
      TO_CHAR(ea.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ea.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM employee_addresses ea JOIN employees e ON e.id=ea.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

-- 4. passport ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_passport(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      p.passport_number AS "Passport Number *",
      COALESCE(picklist_label('ID_COUNTRY',p.country),p.country) AS "Country (ISO3)",
      TO_CHAR(p.issue_date,'MM/DD/YYYY') AS "Issue Date",
      TO_CHAR(p.expiry_date,'MM/DD/YYYY') AS "Expiry Date",
      p.id::text AS "id",
      TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM passports p JOIN employees e ON e.id=p.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

-- 5. identification ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_identification(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      COALESCE(picklist_label('ID_TYPE',ir.id_type),ir.id_type) AS "ID Type *",
      ir.id_number AS "ID Number *", ir.record_type AS "Record Type",
      COALESCE(picklist_label('ID_COUNTRY',ir.country),ir.country) AS "Country (ISO3)",
      TO_CHAR(ir.expiry,'MM/DD/YYYY') AS "Expiry Date",
      ir.id::text AS "id",
      TO_CHAR(ir.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ir.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM identity_records ir JOIN employees e ON e.id=ir.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, ir.id_type) r;
$$;

-- 6. emergency_contact ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_emergency_contact(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ec.name AS "Contact Name *",
      COALESCE(picklist_label('RELATIONSHIP_TYPE',ec.relationship),ec.relationship) AS "Relationship",
      ec.phone AS "Phone", ec.alt_phone AS "Alt Phone", ec.email AS "Email",
      ec.id::text AS "id",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM emergency_contacts ec JOIN employees e ON e.id=ec.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, ec.created_at) r;
$$;

-- 7. employment ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_employment(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(ee.effective_to,  'MM/DD/YYYY') AS "Slice End",
        ee.is_active AS "Slice Is Active",
        COALESCE(picklist_label('DESIGNATION',ee.designation),ee.designation) AS "Designation",
        ee.job_title AS "Job Title", d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date,'MM/DD/YYYY')  AS "End Date",
        COALESCE(picklist_value_label(ee.work_country),ee.work_country) AS "Work Country (ISO3)",
        COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location) AS "Work Location",
        c.code AS "Base Currency", ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee JOIN employees e ON e.id=ee.employee_id
      LEFT JOIN departments d ON d.id=ee.dept_id
      LEFT JOIN employees mgr ON mgr.id=ee.manager_id
      LEFT JOIN currencies c  ON c.id=ee.base_currency_id
      WHERE (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ee.effective_from) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        COALESCE(picklist_label('DESIGNATION',ee.designation),ee.designation) AS "Designation",
        ee.job_title AS "Job Title", d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date,'MM/DD/YYYY')  AS "End Date",
        COALESCE(picklist_value_label(ee.work_country),ee.work_country) AS "Work Country (ISO3)",
        COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location) AS "Work Location",
        c.code AS "Base Currency", ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee JOIN employees e ON e.id=ee.employee_id
      LEFT JOIN departments d ON d.id=ee.dept_id
      LEFT JOIN employees mgr ON mgr.id=ee.manager_id
      LEFT JOIN currencies c  ON c.id=ee.base_currency_id
      WHERE ee.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

-- 8. job_relationships ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_job_relationships(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
        i.relationship_code AS "Relationship Code *", mgr.employee_id AS "Value *",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_job_relationship_set s
      JOIN employee_job_relationship_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id JOIN employees mgr ON mgr.id=i.manager_employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.relationship_code) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.relationship_code AS "Relationship Code *", mgr.employee_id AS "Value *",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_job_relationship_set s
      JOIN employee_job_relationship_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id JOIN employees mgr ON mgr.id=i.manager_employee_id
      WHERE s.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.relationship_code) r;
  END IF;
END; $$;

-- 9. dependents ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_dependents(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
        i.dependent_code AS "Dependent Code *", i.dependent_name AS "Dependent Name *",
        COALESCE((SELECT pv.value FROM picklist_values pv JOIN picklists pl ON pl.id=pv.picklist_id
          WHERE pl.picklist_id='DEPENDENT_RELATIONSHIP_TYPE' AND lower(pv.ref_id)=lower(i.relationship_type)
            AND pv.active=true LIMIT 1), i.relationship_type) AS "Relationship *",
        i.gender AS "Gender", TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s JOIN employee_dependent_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.dependent_code) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.dependent_code AS "Dependent Code *", i.dependent_name AS "Dependent Name *",
        COALESCE((SELECT pv.value FROM picklist_values pv JOIN picklists pl ON pl.id=pv.picklist_id
          WHERE pl.picklist_id='DEPENDENT_RELATIONSHIP_TYPE' AND lower(pv.ref_id)=lower(i.relationship_type)
            AND pv.active=true LIMIT 1), i.relationship_type) AS "Relationship *",
        i.gender AS "Gender", TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s JOIN employee_dependent_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE s.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.dependent_code) r;
  END IF;
END; $$;

-- 10. bank_accounts ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_bank_accounts(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
        i.bank_account_group_id::text AS "Account Group Id *",
        i.country_code AS "Country (ISO3) *", i.currency_code AS "Currency Code *",
        i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name", i.branch_code AS "Branch Code",
        i.account_holder_name AS "Account Holder Name *", i.account_number AS "Account Number *",
        i.ifsc_code AS "IFSC Code", i.iban AS "IBAN", i.swift_bic AS "SWIFT / BIC",
        CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_bank_account_set s JOIN employee_bank_account_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.bank_name) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.bank_account_group_id::text AS "Account Group Id *",
        i.country_code AS "Country (ISO3) *", i.currency_code AS "Currency Code *",
        i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name", i.branch_code AS "Branch Code",
        i.account_holder_name AS "Account Holder Name *", i.account_number AS "Account Number *",
        i.ifsc_code AS "IFSC Code", i.iban AS "IBAN", i.swift_bic AS "SWIFT / BIC",
        CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_bank_account_set s JOIN employee_bank_account_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE s.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive') AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.is_primary DESC, i.bank_name) r;
  END IF;
END; $$;

-- 11. employees ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_employees(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      e.employee_id AS "Employee Code *", e.name AS "Full Name *", e.business_email AS "Business Email",
      COALESCE(picklist_label('DESIGNATION',e.designation),e.designation) AS "Designation",
      e.job_title AS "Job Title", d.dept_id AS "Department Code",
      mgr.employee_id AS "Manager Employee Code",
      TO_CHAR(e.hire_date,'MM/DD/YYYY') AS "Hire Date",
      TO_CHAR(e.end_date, 'MM/DD/YYYY') AS "End Date",
      COALESCE(picklist_value_label(e.work_country),e.work_country) AS "Work Country (ISO3)",
      COALESCE(picklist_label('LOCATION',e.work_location),e.work_location) AS "Work Location",
      c.code AS "Base Currency", e.status::text AS "Status",
      pm01.employee_id AS "PM01 Manager", pm02.employee_id AS "PM02 Manager",
      pm03.employee_id AS "PM03 Manager", om01.employee_id AS "OM01 Manager",
      om02.employee_id AS "OM02 Manager", om03.employee_id AS "OM03 Manager",
      e.id::text AS "id",
      TO_CHAR(e.submitted_at,       'MM/DD/YYYY HH24:MI') AS "Submitted At",
      TO_CHAR(e.invite_sent_at,     'MM/DD/YYYY HH24:MI') AS "Invite Sent At",
      TO_CHAR(e.invite_accepted_at, 'MM/DD/YYYY HH24:MI') AS "Invite Accepted At",
      CASE WHEN e.locked THEN 'Yes' ELSE 'No' END AS "Locked",
      e_creator.name AS "Created By",
      TO_CHAR(e.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(e.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
      TO_CHAR(e.deleted_at,'MM/DD/YYYY HH24:MI') AS "Deleted At"
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
$$;

-- 12. department ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_department(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      d.dept_id AS "Department Code *", d.name AS "Department Name *",
      pd.dept_id AS "Parent Department Code", hd.employee_id AS "Head Employee Code",
      TO_CHAR(d.start_date,'MM/DD/YYYY') AS "Start Date",
      TO_CHAR(d.end_date,  'MM/DD/YYYY') AS "End Date",
      d.id::text AS "id",
      TO_CHAR(d.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(d.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM departments d
    LEFT JOIN departments pd ON pd.id = d.parent_dept_id
    LEFT JOIN employees   hd ON hd.id = d.head_employee_id
    WHERE d.deleted_at IS NULL
    ORDER BY d.dept_id) r;
$$;

-- 13. picklist ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_picklist(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      pl.id::text AS "Picklist Id *", pv.ref_id AS "Ref Id *", pv.value AS "Value *",
      parent_pl.id::text AS "Parent Picklist Id", parent_pv.ref_id AS "Parent Ref Id",
      CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
      pv.meta::text AS "Meta",
      pv.id::text AS "id",
      TO_CHAR(pv.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(pv.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM picklist_values pv JOIN picklists pl ON pl.id=pv.picklist_id
    LEFT JOIN picklist_values parent_pv ON parent_pv.id=pv.parent_value_id
    LEFT JOIN picklists parent_pl ON parent_pl.id=parent_pv.picklist_id
    WHERE (p_include_inactive OR pv.active=true)
    ORDER BY pl.id, pv.ref_id) r;
$$;

-- 14. project ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_project(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT p.name AS "Project Name *",
      TO_CHAR(p.start_date,'MM/DD/YYYY') AS "Start Date",
      TO_CHAR(p.end_date,  'MM/DD/YYYY') AS "End Date",
      CASE WHEN p.active THEN 'Yes' ELSE 'No' END AS "Active",
      p.id::text AS "id",
      TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM projects p WHERE (p_include_inactive OR p.active=true) ORDER BY p.name) r;
$$;

-- 15. exchange_rate ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_exchange_rate(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT fc.code AS "From Currency *", tc.code AS "To Currency *",
      TO_CHAR(er.effective_date,'MM/DD/YYYY') AS "Effective Date *",
      er.rate::text AS "Rate *",
      er.id::text AS "id",
      TO_CHAR(er.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(er.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM exchange_rates er
    JOIN currencies fc ON fc.id=er.from_currency_id
    JOIN currencies tc ON tc.id=er.to_currency_id
    ORDER BY fc.code, tc.code, er.effective_date) r;
$$;

-- 16. education ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_education(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        ee.education_level AS "Education Level Code *", ee.degree AS "Degree *",
        ee.institution AS "Institution *",
        TO_CHAR(ee.start_date,'MM/DD/YYYY') AS "Start Date *",
        TO_CHAR(ee.end_date,  'MM/DD/YYYY') AS "End Date",
        ee.completion_status AS "Completion Status Code *",
        ee.grade_or_gpa AS "Grade / GPA",
        CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification",
        CASE WHEN ee.is_active THEN 'Yes' ELSE 'No' END AS "Is Active",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_education ee JOIN employees e ON e.id=ee.employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ee.is_active DESC,
               ee.is_highest_qualification DESC,
               ee.end_date DESC NULLS FIRST, ee.start_date DESC) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        ee.education_level AS "Education Level Code *", ee.degree AS "Degree *",
        ee.institution AS "Institution *",
        TO_CHAR(ee.start_date,'MM/DD/YYYY') AS "Start Date *",
        TO_CHAR(ee.end_date,  'MM/DD/YYYY') AS "End Date",
        ee.completion_status AS "Completion Status Code *",
        ee.grade_or_gpa AS "Grade / GPA",
        CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_education ee JOIN employees e ON e.id=ee.employee_id
      WHERE ee.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id,
               ee.is_highest_qualification DESC,
               ee.end_date DESC NULLS FIRST, ee.start_date DESC) r;
  END IF;
END; $$;


-- =============================================================================
-- PART 2 — Stable dispatcher (replaces the 400-line monolith forever)
--
-- This function never needs to change again. Adding a new template = create
-- _bulk_export_{code}() and register it in bulk_template_registry. Done.
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
DECLARE
  v_fn_name TEXT;
BEGIN
  -- 1. Validate template exists in registry (also prevents SQL injection)
  IF NOT EXISTS (
    SELECT 1 FROM bulk_template_registry WHERE template_code = p_template_code
  ) THEN
    RAISE EXCEPTION 'Unknown template_code: %', p_template_code;
  END IF;

  -- 2. Permission check
  IF NOT user_can(p_template_code, 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_export required', p_template_code
      USING ERRCODE = '42501';
  END IF;

  -- 3. Dispatch to per-template function via safe identifier quoting (%I)
  --    Function name: _bulk_export_{template_code}
  --    %I prevents SQL injection — only valid identifiers can be constructed.
  v_fn_name := '_bulk_export_' || p_template_code;

  RETURN QUERY EXECUTE
    format('SELECT * FROM %I($1, $2)', v_fn_name)
    USING p_include_inactive, p_mode;

EXCEPTION
  WHEN undefined_function THEN
    RAISE EXCEPTION
      'No export function found for template "%". '
      'Create _bulk_export_%s(BOOLEAN, TEXT) to register it.',
      p_template_code, p_template_code;
END;
$$;

COMMENT ON FUNCTION bulk_export IS
  'Mig 423: stable dispatcher — calls _bulk_export_{template_code}(). '
  'Adding a new template requires only a new _bulk_export_* function. '
  'This dispatcher never needs to change again. '
  'See docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 3 — Grant execute on all per-template functions
-- =============================================================================

GRANT EXECUTE ON FUNCTION _bulk_export_personal_info(BOOLEAN, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_contact_info(BOOLEAN, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_address(BOOLEAN, TEXT)          TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_passport(BOOLEAN, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_identification(BOOLEAN, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_emergency_contact(BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employment(BOOLEAN, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_job_relationships(BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_dependents(BOOLEAN, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_bank_accounts(BOOLEAN, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employees(BOOLEAN, TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_department(BOOLEAN, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_picklist(BOOLEAN, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_project(BOOLEAN, TEXT)          TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_exchange_rate(BOOLEAN, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_education(BOOLEAN, TEXT)        TO authenticated;


-- =============================================================================
-- PART 4 — Fix picklist schema_definition: remove "Sort Order"
--
-- sort_order column was referenced in mig 375 seed's exporter_query and carried
-- into mig 413's schema_definition UPDATE, but the column was never added to the
-- picklist_values table. Remove it from the schema so the template and download
-- template don't include a column that can never be populated.
-- =============================================================================

UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col ORDER BY ord) FROM (VALUES
    (jsonb_build_object('name','Picklist Id *',      'data_type','text','mandatory',true, 'user_fillable',true,'description','The picklist identifier, e.g. ID_COUNTRY'), 1),
    (jsonb_build_object('name','Ref Id *',           'data_type','text','mandatory',true, 'user_fillable',true,'description','Short code uniquely identifying this value, e.g. IND'), 2),
    (jsonb_build_object('name','Value *',            'data_type','text','mandatory',true, 'user_fillable',true,'description','Display label, e.g. India'), 3),
    (jsonb_build_object('name','Parent Picklist Id', 'data_type','text','mandatory',false,'user_fillable',true,'description','For cascading values: the parent picklist identifier'), 4),
    (jsonb_build_object('name','Parent Ref Id',      'data_type','text','mandatory',false,'user_fillable',true,'description','For cascading values: the ref_id of the parent value'), 5),
    (jsonb_build_object('name','Active',             'data_type','yesno','mandatory',false,'user_fillable',true,'description','Yes (default) or No to deactivate'), 6),
    (jsonb_build_object('name','Meta',               'data_type','text','mandatory',false,'user_fillable',true,'description','Optional JSON metadata. Must be valid JSON if provided.'), 7),
    (jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8),
    (jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9),
    (jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10)
  ) AS t(col, ord)),
  'natural_key',   jsonb_build_array('Picklist Id *','Ref Id *'),
  'row_processor', 'per_row'
), updated_at=NOW() WHERE template_code='picklist';

-- =============================================================================
-- VERIFICATION
-- =============================================================================
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM information_schema.routines
  WHERE routine_schema = 'public'
    AND routine_name LIKE '_bulk_export_%';

  IF v_count < 16 THEN
    RAISE EXCEPTION 'Expected 16 _bulk_export_* functions, found %', v_count;
  END IF;
END $$;

-- =============================================================================
-- END OF MIGRATION 423
-- =============================================================================
