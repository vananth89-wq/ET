-- =============================================================================
-- Migration 452 — Fix current export: add effective_to='9999-12-31' filter
--
-- All set-snapshot and effective-dated tables use (is_active=true, effective_to=9999-12-31)
-- to identify the current open-ended slice. The current export mode was only
-- filtering on is_active=true, returning all historical active slices too.
--
-- Templates fixed here: dependents, job_relationships, bank_accounts
-- (employment was fixed in mig 451, personal_info was already correct)
-- =============================================================================

-- ── dependents ────────────────────────────────────────────────────────────────
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
        AND s.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.dependent_code) r;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION _bulk_export_dependents(BOOLEAN, TEXT) TO authenticated;

-- ── job_relationships ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_job_relationships(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End",
        s.is_active AS "Slice Is Active",
        i.relationship_code AS "Relationship Code *",
        mgr.employee_id AS "Value *",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_job_relationship_set s
      JOIN employee_job_relationship_item i ON i.set_id = s.id
      JOIN employees e   ON e.id   = s.employee_id
      JOIN employees mgr ON mgr.id = i.manager_employee_id
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.relationship_code) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.relationship_code AS "Relationship Code *",
        mgr.employee_id AS "Value *",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_job_relationship_set s
      JOIN employee_job_relationship_item i ON i.set_id = s.id
      JOIN employees e   ON e.id   = s.employee_id
      JOIN employees mgr ON mgr.id = i.manager_employee_id
      WHERE s.is_active = true
        AND s.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.relationship_code) r;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION _bulk_export_job_relationships(BOOLEAN, TEXT) TO authenticated;

-- ── bank_accounts ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _bulk_export_bank_accounts(
  p_include_inactive BOOLEAN, p_mode TEXT
) RETURNS SETOF JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_mode = 'history' THEN
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        TO_CHAR(s.effective_to,  'MM/DD/YYYY') AS "Slice End",
        s.is_active AS "Slice Is Active",
        i.bank_account_group_id::text AS "Account Group Id *",
        i.country_code AS "Country (ISO3) *", i.currency_code AS "Currency Code *",
        i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name",
        i.branch_code AS "Branch Code",
        i.account_holder_name AS "Account Holder Name *",
        i.account_number AS "Account Number *",
        i.ifsc_code AS "IFSC Code", i.iban AS "IBAN", i.swift_bic AS "SWIFT / BIC",
        CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_bank_account_set s
      JOIN employee_bank_account_item i ON i.set_id = s.id
      JOIN employees e ON e.id = s.employee_id
      WHERE (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, s.effective_from, i.bank_name) r;
  ELSE
    RETURN QUERY SELECT to_jsonb(r) FROM (
      SELECT e.employee_id AS "Employee Code *",
        TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
        i.bank_account_group_id::text AS "Account Group Id *",
        i.country_code AS "Country (ISO3) *", i.currency_code AS "Currency Code *",
        i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name",
        i.branch_code AS "Branch Code",
        i.account_holder_name AS "Account Holder Name *",
        i.account_number AS "Account Number *",
        i.ifsc_code AS "IFSC Code", i.iban AS "IBAN", i.swift_bic AS "SWIFT / BIC",
        CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary",
        s.id::text AS "id",
        TO_CHAR(s.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
        TO_CHAR(s.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
      FROM employee_bank_account_set s
      JOIN employee_bank_account_item i ON i.set_id = s.id
      JOIN employees e ON e.id = s.employee_id
      WHERE s.is_active = true
        AND s.effective_to = '9999-12-31'::date
        AND (p_include_inactive OR e.status <> 'Inactive')
        AND e.status NOT IN ('Draft','Incomplete')
      ORDER BY e.employee_id, i.is_primary DESC, i.bank_name) r;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION _bulk_export_bank_accounts(BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION _bulk_export_dependents(boolean, text)     IS 'Mig 452: added effective_to=9999-12-31 to current mode filter.';
COMMENT ON FUNCTION _bulk_export_job_relationships(boolean, text) IS 'Mig 452: added effective_to=9999-12-31 to current mode filter.';
COMMENT ON FUNCTION _bulk_export_bank_accounts(boolean, text)  IS 'Mig 452: added effective_to=9999-12-31 to current mode filter.';
