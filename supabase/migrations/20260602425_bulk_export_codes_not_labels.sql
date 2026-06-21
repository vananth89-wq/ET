-- =============================================================================
-- Migration 425 — bulk_export: export codes not labels for all user-fillable
--                 picklist fields
--
-- PROBLEM: Several _bulk_export_* functions wrapped picklist columns in
-- picklist_label() / picklist_value_label() to show human-readable labels.
-- This breaks round-trip safety — the exported label may not resolve on
-- re-import if a picklist value has been renamed.
--
-- RULE: User-fillable picklist fields must export the stored code (ref_id),
-- never the display label. Labels are human-readable but not stable keys.
--
-- Two storage patterns:
--   A. ref_id stored directly (TEXT column):
--      designation, work_location, marital_status, id_type, country (passport/id),
--      relationship (emergency_contact), relationship_type (dependents)
--      FIX: remove COALESCE(picklist_label(...), raw) → use raw column directly
--
--   B. UUID stored (picklist_value.id as TEXT):
--      work_country in employee_employment + employees
--      FIX: LEFT JOIN picklist_values to get ref_id
--
-- System metadata columns (id, timestamps) are unaffected.
-- =============================================================================

-- ─── 1. personal_info ─────────────────────────────────────────────────────────
-- marital_status stored as ref_id — remove label wrapper
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
        ep.gender AS "Gender",
        TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        ep.marital_status AS "Marital Status",
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
        ep.gender AS "Gender",
        TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
        ep.nationality AS "Nationality (ISO3)",
        ep.marital_status AS "Marital Status",
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

-- ─── 4. passport ──────────────────────────────────────────────────────────────
-- country stored as ref_id — remove label wrapper
CREATE OR REPLACE FUNCTION _bulk_export_passport(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      p.passport_number AS "Passport Number *",
      p.country AS "Country (ISO3)",
      TO_CHAR(p.issue_date, 'MM/DD/YYYY') AS "Issue Date",
      TO_CHAR(p.expiry_date,'MM/DD/YYYY') AS "Expiry Date",
      p.id::text AS "id",
      TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM passports p JOIN employees e ON e.id=p.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

-- ─── 5. identification ────────────────────────────────────────────────────────
-- id_type and country stored as ref_id — remove label wrappers
CREATE OR REPLACE FUNCTION _bulk_export_identification(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ir.id_type   AS "ID Type *",
      ir.id_number AS "ID Number *",
      ir.record_type AS "Record Type",
      ir.country   AS "Country (ISO3)",
      TO_CHAR(ir.expiry,'MM/DD/YYYY') AS "Expiry Date",
      ir.id::text AS "id",
      TO_CHAR(ir.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ir.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM identity_records ir JOIN employees e ON e.id=ir.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, ir.id_type) r;
$$;

-- ─── 6. emergency_contact ─────────────────────────────────────────────────────
-- relationship stored as ref_id — remove label wrapper
CREATE OR REPLACE FUNCTION _bulk_export_emergency_contact(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ec.name         AS "Contact Name *",
      ec.relationship AS "Relationship",
      ec.phone AS "Phone", ec.alt_phone AS "Alt Phone", ec.email AS "Email",
      ec.id::text AS "id",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM emergency_contacts ec JOIN employees e ON e.id=ec.employee_id
    WHERE (p_include_inactive OR e.status<>'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, ec.created_at) r;
$$;

-- ─── 7. employment ────────────────────────────────────────────────────────────
-- designation + work_location: stored as ref_id — remove label wrappers
-- work_country: stored as UUID — JOIN picklist_values to get ref_id
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
        ee.designation AS "Designation",
        ee.job_title AS "Job Title",
        d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date, 'MM/DD/YYYY') AS "End Date",
        pv_wc.ref_id AS "Work Country (ISO3)",
        ee.work_location AS "Work Location",
        c.code AS "Base Currency",
        ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e ON e.id=ee.employee_id
      LEFT JOIN departments d   ON d.id=ee.dept_id
      LEFT JOIN employees mgr   ON mgr.id=ee.manager_id
      LEFT JOIN currencies c    ON c.id=ee.base_currency_id
      LEFT JOIN picklist_values pv_wc ON pv_wc.id::text = ee.work_country
      WHERE (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ee.effective_from) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        ee.designation AS "Designation",
        ee.job_title AS "Job Title",
        d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date, 'MM/DD/YYYY') AS "End Date",
        pv_wc.ref_id AS "Work Country (ISO3)",
        ee.work_location AS "Work Location",
        c.code AS "Base Currency",
        ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e ON e.id=ee.employee_id
      LEFT JOIN departments d   ON d.id=ee.dept_id
      LEFT JOIN employees mgr   ON mgr.id=ee.manager_id
      LEFT JOIN currencies c    ON c.id=ee.base_currency_id
      LEFT JOIN picklist_values pv_wc ON pv_wc.id::text = ee.work_country
      WHERE ee.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

-- ─── 9. dependents ────────────────────────────────────────────────────────────
-- relationship_type stored as ref_id — remove subquery label lookup
CREATE OR REPLACE FUNCTION _bulk_export_dependents(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End",
        s.is_active AS "Slice Is Active",
        i.dependent_code AS "Dependent Code *",
        i.dependent_name AS "Dependent Name *",
        i.relationship_type AS "Relationship *",
        i.gender AS "Gender",
        TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s
      JOIN employee_dependent_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.dependent_code) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.dependent_code AS "Dependent Code *",
        i.dependent_name AS "Dependent Name *",
        i.relationship_type AS "Relationship *",
        i.gender AS "Gender",
        TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s
      JOIN employee_dependent_item i ON i.set_id=s.id
      JOIN employees e ON e.id=s.employee_id
      WHERE s.is_active=true
        AND (p_include_inactive OR e.status<>'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.dependent_code) r;
  END IF;
END; $$;

-- ─── 11. employees (master) ───────────────────────────────────────────────────
-- designation + work_location: stored as ref_id — remove label wrappers
-- work_country: stored as UUID — JOIN picklist_values to get ref_id
CREATE OR REPLACE FUNCTION _bulk_export_employees(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      e.employee_id AS "Employee Code *", e.name AS "Full Name *",
      e.business_email AS "Business Email",
      e.designation AS "Designation",
      e.job_title AS "Job Title",
      d.dept_id AS "Department Code",
      mgr.employee_id AS "Manager Employee Code",
      TO_CHAR(e.hire_date,'MM/DD/YYYY') AS "Hire Date",
      TO_CHAR(e.end_date, 'MM/DD/YYYY') AS "End Date",
      pv_wc.ref_id AS "Work Country (ISO3)",
      e.work_location AS "Work Location",
      c.code AS "Base Currency",
      e.status::text AS "Status",
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
    LEFT JOIN picklist_values pv_wc ON pv_wc.id::text = e.work_country
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

-- ─── Grants ───────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION _bulk_export_personal_info(BOOLEAN, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_passport(BOOLEAN, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_identification(BOOLEAN, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_emergency_contact(BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employment(BOOLEAN, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_dependents(BOOLEAN, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employees(BOOLEAN, TEXT)        TO authenticated;

-- =============================================================================
-- END OF MIGRATION 425
-- =============================================================================
