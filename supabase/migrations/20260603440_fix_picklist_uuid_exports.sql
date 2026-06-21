-- =============================================================================
-- Migration 430 — Fix bulk exports: picklist UUID fields → ref_id
--
-- PROBLEM: Mig 425 assumed several picklist columns were stored as ref_id
-- (Pattern A) and removed picklist_label() wrappers. In reality all of these
-- fields call resolve_picklist_id() on import which stores a UUID (Pattern B).
-- Result: exports emit raw UUIDs which are unreadable and opaque.
--
-- Affected fields and tables:
--   employee_personal.marital_status      → picklist_values JOIN on id
--   employee_employment.designation       → picklist_values JOIN on id
--   employee_employment.work_location     → picklist_values JOIN on id
--   employees.designation                 → picklist_values JOIN on id
--   employees.work_location               → picklist_values JOIN on id
--   identity_records.id_type              → picklist_values JOIN on id
--   identity_records.country              → picklist_values JOIN on id
--   emergency_contacts.relationship       → picklist_values JOIN on id
--   employee_dependent_item.relationship_type → picklist_values JOIN on id
--
-- FIX: Switch all to Pattern B — LEFT JOIN picklist_values to get ref_id.
-- This matches the existing work_country treatment in mig 425.
--
-- Round-trip safety: exported ref_ids (M001, D002, etc.) are accepted on
-- re-import via resolve_picklist_id() which accepts label, ref_id, or UUID.
-- =============================================================================

-- ─── 1. personal_info ─────────────────────────────────────────────────────────
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
        pv_ms.ref_id AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep
      JOIN employees e ON e.id = ep.employee_id
      LEFT JOIN picklist_values pv_ms ON pv_ms.id::text = ep.marital_status
      WHERE (p_include_inactive OR e.status <> 'Inactive')
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
        pv_ms.ref_id AS "Marital Status",
        ep.id::text AS "id",
        TO_CHAR(ep.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ep.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ep.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_personal ep
      JOIN employees e ON e.id = ep.employee_id
      LEFT JOIN picklist_values pv_ms ON pv_ms.id::text = ep.marital_status
      WHERE ep.is_active = true AND ep.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

-- ─── 5. identification ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_identification(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      pv_type.ref_id    AS "ID Type *",
      ir.id_number      AS "ID Number *",
      ir.record_type    AS "Record Type",
      pv_ctry.ref_id    AS "Country (ISO3)",
      TO_CHAR(ir.expiry,'MM/DD/YYYY') AS "Expiry Date",
      ir.id::text AS "id",
      TO_CHAR(ir.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ir.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM identity_records ir
    JOIN employees e ON e.id = ir.employee_id
    LEFT JOIN picklist_values pv_type ON pv_type.id::text = ir.id_type
    LEFT JOIN picklist_values pv_ctry ON pv_ctry.id::text = ir.country
    WHERE (p_include_inactive OR e.status <> 'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, pv_type.ref_id) r;
$$;

-- ─── 6. emergency_contact ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_emergency_contact(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT e.employee_id AS "Employee Code *",
      ec.name            AS "Contact Name *",
      pv_rel.ref_id      AS "Relationship",
      ec.phone AS "Phone", ec.alt_phone AS "Alt Phone", ec.email AS "Email",
      ec.id::text AS "id",
      TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
      TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
    FROM emergency_contacts ec
    JOIN employees e ON e.id = ec.employee_id
    LEFT JOIN picklist_values pv_rel ON pv_rel.id::text = ec.relationship
    WHERE (p_include_inactive OR e.status <> 'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id, ec.created_at) r;
$$;

-- ─── 7. employment ────────────────────────────────────────────────────────────
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
        pv_des.ref_id AS "Designation",
        ee.job_title AS "Job Title",
        d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date, 'MM/DD/YYYY') AS "End Date",
        pv_wc.ref_id  AS "Work Country (ISO3)",
        pv_loc.ref_id AS "Work Location",
        c.code AS "Base Currency",
        ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e ON e.id = ee.employee_id
      LEFT JOIN departments d      ON d.id         = ee.dept_id
      LEFT JOIN employees mgr      ON mgr.id        = ee.manager_id
      LEFT JOIN currencies c       ON c.id          = ee.base_currency_id
      LEFT JOIN picklist_values pv_wc  ON pv_wc.id::text  = ee.work_country
      LEFT JOIN picklist_values pv_des ON pv_des.id::text = ee.designation
      LEFT JOIN picklist_values pv_loc ON pv_loc.id::text = ee.work_location
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, ee.effective_from) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT
        e.employee_id AS "Employee Code *",
        TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        pv_des.ref_id AS "Designation",
        ee.job_title AS "Job Title",
        d.dept_id AS "Department Code",
        mgr.employee_id AS "Manager Employee Code",
        TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
        TO_CHAR(ee.end_date, 'MM/DD/YYYY') AS "End Date",
        pv_wc.ref_id  AS "Work Country (ISO3)",
        pv_loc.ref_id AS "Work Location",
        c.code AS "Base Currency",
        ee.status::text AS "Status",
        ee.id::text AS "id",
        TO_CHAR(ee.created_at, 'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(ee.updated_at, 'MM/DD/YYYY HH24:MI') AS "Updated At",
        TO_CHAR(ee.inactive_at,'MM/DD/YYYY HH24:MI') AS "Inactive At"
      FROM employee_employment ee
      JOIN employees e ON e.id = ee.employee_id
      LEFT JOIN departments d      ON d.id         = ee.dept_id
      LEFT JOIN employees mgr      ON mgr.id        = ee.manager_id
      LEFT JOIN currencies c       ON c.id          = ee.base_currency_id
      LEFT JOIN picklist_values pv_wc  ON pv_wc.id::text  = ee.work_country
      LEFT JOIN picklist_values pv_des ON pv_des.id::text = ee.designation
      LEFT JOIN picklist_values pv_loc ON pv_loc.id::text = ee.work_location
      WHERE ee.is_active = true
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

-- ─── 9. dependents ────────────────────────────────────────────────────────────
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
        pv_rel.ref_id    AS "Relationship *",
        i.gender AS "Gender",
        TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s
      JOIN employee_dependent_item i ON i.set_id = s.id
      JOIN employees e ON e.id = s.employee_id
      LEFT JOIN picklist_values pv_rel ON pv_rel.id::text = i.relationship_type
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.dependent_code) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.dependent_code AS "Dependent Code *",
        i.dependent_name AS "Dependent Name *",
        pv_rel.ref_id    AS "Relationship *",
        i.gender AS "Gender",
        TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
        CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_dependent_set s
      JOIN employee_dependent_item i ON i.set_id = s.id
      JOIN employees e ON e.id = s.employee_id
      LEFT JOIN picklist_values pv_rel ON pv_rel.id::text = i.relationship_type
      WHERE s.is_active = true
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.dependent_code) r;
  END IF;
END; $$;

-- ─── 11. employees (master) ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_employees(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_jsonb(r) FROM (
    SELECT
      e.employee_id AS "Employee Code *", e.name AS "Full Name *",
      e.business_email AS "Business Email",
      pv_des.ref_id AS "Designation",
      e.job_title AS "Job Title",
      d.dept_id AS "Department Code",
      mgr.employee_id AS "Manager Employee Code",
      TO_CHAR(e.hire_date,'MM/DD/YYYY') AS "Hire Date",
      TO_CHAR(e.end_date, 'MM/DD/YYYY') AS "End Date",
      pv_wc.ref_id  AS "Work Country (ISO3)",
      pv_loc.ref_id AS "Work Location",
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
    LEFT JOIN departments d      ON d.id         = e.dept_id
    LEFT JOIN employees mgr      ON mgr.id        = e.manager_id
    LEFT JOIN currencies c       ON c.id          = e.base_currency_id
    LEFT JOIN picklist_values pv_wc  ON pv_wc.id::text  = e.work_country
    LEFT JOIN picklist_values pv_des ON pv_des.id::text = e.designation
    LEFT JOIN picklist_values pv_loc ON pv_loc.id::text = e.work_location
    LEFT JOIN employees pm01    ON pm01.id        = e.pm01_manager_id
    LEFT JOIN employees pm02    ON pm02.id        = e.pm02_manager_id
    LEFT JOIN employees pm03    ON pm03.id        = e.pm03_manager_id
    LEFT JOIN employees om01    ON om01.id        = e.om01_manager_id
    LEFT JOIN employees om02    ON om02.id        = e.om02_manager_id
    LEFT JOIN employees om03      ON om03.id      = e.om03_manager_id
    LEFT JOIN profiles  p_creator ON p_creator.id = e.created_by
    LEFT JOIN employees e_creator ON e_creator.id = p_creator.employee_id
    WHERE (p_include_inactive OR e.status <> 'Inactive')
      AND e.status NOT IN ('Draft','Incomplete')
    ORDER BY e.employee_id) r;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION _bulk_export_personal_info(BOOLEAN, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_identification(BOOLEAN, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_emergency_contact(BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employment(BOOLEAN, TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_dependents(BOOLEAN, TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION _bulk_export_employees(BOOLEAN, TEXT)         TO authenticated;

-- =============================================================================
-- END OF MIGRATION 429
-- =============================================================================
