-- =============================================================================
-- Migration 451 — Fix employment current export: add effective_to filter
--
-- PROBLEM: _bulk_export_employment current mode filtered only on is_active=true,
-- returning ALL active slices (historical + current). For effective-dated tables
-- the current slice is identified by is_active=true AND effective_to='9999-12-31'.
--
-- Same issue existed in _bulk_export_personal_info (mig 440 already fixed it).
-- =============================================================================

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
    -- Current: open-ended active slice only (is_active=true AND effective_to=9999-12-31)
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
        AND ee.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id) r;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION _bulk_export_employment(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_employment(boolean, text) IS
  'Mig 451: current mode now filters is_active=true AND effective_to=9999-12-31 '
  'to return only the open-ended current slice per employee (was returning all active slices).';
