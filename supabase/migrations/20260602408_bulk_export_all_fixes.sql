-- =============================================================================
-- Migration 408 — Consolidate all bulk_export fixes + complete column coverage
--
-- Applies all hotfix SQL run directly in Supabase SQL editor since mig 403,
-- and adds missing columns across all 15 templates based on actual DB schema.
--
-- Changes vs previous live version (mig 403):
--   HELPERS
--     + picklist_value_label(uuid)        — generic UUID→label (work_country)
--     + picklist_label_by_ref(code,ref)   — ref_id→label (dependent relationship)
--
--   PROCESSOR FIXES
--     + upsert_emergency_contact          — resolve relationship on import
--
--   EXPORT GAPS FILLED
--     personal_info   + preferred_name; system meta: id, created_by, updated_by,
--                       inactive_at, inactive_by, created_at, updated_at
--     contact_info    + system meta: id, created_at, updated_at
--     address         + system meta: id, created_at, updated_at
--     passport        + system meta: id, created_at, updated_at
--     identification  + record_type; system meta: id, created_at, updated_at
--     emergency_contact + system meta: id, created_at, updated_at
--     employment      + system meta: id, created_by, updated_by,
--                       inactive_at, inactive_by, created_at, updated_at
--     job_relationships + system meta: id, created_at, updated_at
--     dependents      + gender; system meta: id, created_by, created_at, updated_at
--     bank_accounts   + system meta: id, created_by, created_at, updated_at
--     employees       + pm01–om03 mirror managers; system meta: id, invite fields,
--                       locked, created_at, updated_at
--     department      + parent_dept_id→code, head→code, start_date, end_date;
--                       system meta: id, created_at, updated_at
--     picklist        — no changes (already complete)
--     project         + system meta: id, created_at, updated_at
--     exchange_rate   + system meta: id, created_at, updated_at
-- =============================================================================


-- =============================================================================
-- PART 1 — Helper functions
-- =============================================================================

CREATE OR REPLACE FUNCTION picklist_value_label(p_uuid_text text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT value FROM picklist_values WHERE id::text = p_uuid_text LIMIT 1;
$$;
COMMENT ON FUNCTION picklist_value_label(text) IS
  'Generic UUID→label with no picklist_id filter. Used for work_country.';
GRANT EXECUTE ON FUNCTION picklist_value_label(text) TO authenticated;


CREATE OR REPLACE FUNCTION picklist_label_by_ref(p_picklist_code text, p_ref_id text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT pv.value
  FROM   picklist_values pv
  JOIN   picklists pl ON pl.id = pv.picklist_id
  WHERE  pl.picklist_id   = p_picklist_code
    AND  lower(pv.ref_id) = lower(trim(p_ref_id))
    AND  pv.active        = true
  LIMIT 1;
$$;
COMMENT ON FUNCTION picklist_label_by_ref(text, text) IS
  'ref_id→label lookup. Used for dependent relationship_type.';
GRANT EXECUTE ON FUNCTION picklist_label_by_ref(text, text) TO authenticated;


-- =============================================================================
-- PART 2 — upsert_emergency_contact: resolve relationship on import
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_relationship text;
  v_valid        text;
BEGIN
  IF NOT user_can('emergency_contacts', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: emergency_contact.bulk_import required');
  END IF;
  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;
  v_relationship := NULL;
  IF NULLIF(p_row->>'relationship', '') IS NOT NULL THEN
    v_relationship := resolve_picklist_id('RELATIONSHIP_TYPE', trim(p_row->>'relationship'));
    IF v_relationship IS NULL THEN
      SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv JOIN picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'RELATIONSHIP_TYPE' AND pv.active = true;
      RETURN jsonb_build_object('ok', false,
        'error', 'Unknown Relationship "' || (p_row->>'relationship') || '". Valid values: ' || COALESCE(v_valid, '(none)'));
    END IF;
  END IF;
  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (p_employee_id, p_row->>'name', v_relationship,
          NULLIF(p_row->>'phone',''), NULLIF(p_row->>'alt_phone',''), NULLIF(p_row->>'email',''))
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = COALESCE(EXCLUDED.relationship,         emergency_contacts.relationship),
    phone        = COALESCE(NULLIF(EXCLUDED.phone,''),     emergency_contacts.phone),
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone,''), emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,''),     emergency_contacts.email),
    updated_at   = NOW();
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION upsert_emergency_contact(UUID, JSONB) TO authenticated;


-- =============================================================================
-- PART 3 — bulk_export: complete replacement, all 15 templates
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
            COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),
                     ep.marital_status)                                               AS "Marital Status",
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
            COALESCE(picklist_label('MARITAL_STATUS',ep.marital_status),
                     ep.marital_status)                                               AS "Marital Status",
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
          e.employee_id                              AS "Employee Code *",
          ec.personal_email                          AS "Personal Email",
          ec.country_code                            AS "Country Code",
          ec.mobile                                  AS "Mobile",
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
          e.employee_id                               AS "Employee Code *",
          ea.line1                                    AS "Line 1",
          ea.line2                                    AS "Line 2",
          ea.landmark                                 AS "Landmark",
          ea.city                                     AS "City",
          ea.district                                 AS "District",
          ea.state                                    AS "State",
          ea.pin                                      AS "Postal Code",
          ea.country                                  AS "Country (ISO3)",
          ea.id::text                                 AS "id",
          TO_CHAR(ea.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
          TO_CHAR(ea.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
        FROM employee_addresses ea JOIN employees e ON e.id=ea.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive') ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 4. passport
    -- =========================================================================
    WHEN 'passport' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                               AS "Employee Code *",
          p.passport_number                           AS "Passport Number *",
          COALESCE(picklist_label('ID_COUNTRY',p.country),p.country) AS "Country (ISO3)",
          TO_CHAR(p.issue_date, 'MM/DD/YYYY')         AS "Issue Date",
          TO_CHAR(p.expiry_date,'MM/DD/YYYY')         AS "Expiry Date",
          p.id::text                                  AS "id",
          TO_CHAR(p.created_at,'MM/DD/YYYY HH24:MI')  AS "Created At",
          TO_CHAR(p.updated_at,'MM/DD/YYYY HH24:MI')  AS "Updated At"
        FROM passports p JOIN employees e ON e.id=p.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive') ORDER BY e.employee_id) r;

    -- =========================================================================
    -- 5. identification
    -- =========================================================================
    WHEN 'identification' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                               AS "Employee Code *",
          COALESCE(picklist_label('ID_TYPE',ir.id_type),ir.id_type)   AS "ID Type *",
          ir.id_number                                AS "ID Number *",
          ir.record_type                              AS "Record Type",
          COALESCE(picklist_label('ID_COUNTRY',ir.country),ir.country) AS "Country (ISO3)",
          TO_CHAR(ir.expiry,'MM/DD/YYYY')             AS "Expiry Date",
          ir.id::text                                 AS "id",
          TO_CHAR(ir.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
          TO_CHAR(ir.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
        FROM identity_records ir JOIN employees e ON e.id=ir.employee_id
        WHERE (p_include_inactive OR e.status<>'Inactive')
        ORDER BY e.employee_id, ir.id_type) r;

    -- =========================================================================
    -- 6. emergency_contact
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          e.employee_id                               AS "Employee Code *",
          ec.name                                     AS "Contact Name *",
          COALESCE(picklist_label('RELATIONSHIP_TYPE',ec.relationship),ec.relationship) AS "Relationship",
          ec.phone                                    AS "Phone",
          ec.alt_phone                                AS "Alt Phone",
          ec.email                                    AS "Email",
          ec.id::text                                 AS "id",
          TO_CHAR(ec.created_at,'MM/DD/YYYY HH24:MI') AS "Created At",
          TO_CHAR(ec.updated_at,'MM/DD/YYYY HH24:MI') AS "Updated At"
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
            COALESCE(picklist_value_label(ee.work_country),ee.work_country)             AS "Work Country (ISO3)",
            COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location)      AS "Work Location",
            c.code                                                                     AS "Base Currency",
            ee.status::text                                                            AS "Status",
            ee.id::text                                                                AS "id",
            TO_CHAR(ee.created_at,  'MM/DD/YYYY HH24:MI')                              AS "Created At",
            TO_CHAR(ee.updated_at,  'MM/DD/YYYY HH24:MI')                              AS "Updated At",
            TO_CHAR(ee.inactive_at, 'MM/DD/YYYY HH24:MI')                              AS "Inactive At"
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
            COALESCE(picklist_value_label(ee.work_country),ee.work_country)             AS "Work Country (ISO3)",
            COALESCE(picklist_label('LOCATION',ee.work_location),ee.work_location)      AS "Work Location",
            c.code                                                                     AS "Base Currency",
            ee.status::text                                                            AS "Status",
            ee.id::text                                                                AS "id",
            TO_CHAR(ee.created_at,  'MM/DD/YYYY HH24:MI')                              AS "Created At",
            TO_CHAR(ee.updated_at,  'MM/DD/YYYY HH24:MI')                              AS "Updated At",
            TO_CHAR(ee.inactive_at, 'MM/DD/YYYY HH24:MI')                              AS "Inactive At"
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
          TO_CHAR(e.created_at, 'MM/DD/YYYY HH24:MI')                             AS "Created At",
          TO_CHAR(e.updated_at, 'MM/DD/YYYY HH24:MI')                             AS "Updated At",
          TO_CHAR(e.deleted_at, 'MM/DD/YYYY HH24:MI')                             AS "Deleted At"
        FROM employees e
        LEFT JOIN departments d    ON d.id    = e.dept_id
        LEFT JOIN employees   mgr  ON mgr.id  = e.manager_id
        LEFT JOIN currencies  c    ON c.id    = e.base_currency_id
        LEFT JOIN employees   pm01 ON pm01.id = e.pm01_manager_id
        LEFT JOIN employees   pm02 ON pm02.id = e.pm02_manager_id
        LEFT JOIN employees   pm03 ON pm03.id = e.pm03_manager_id
        LEFT JOIN employees   om01 ON om01.id = e.om01_manager_id
        LEFT JOIN employees   om02 ON om02.id = e.om02_manager_id
        LEFT JOIN employees   om03       ON om03.id       = e.om03_manager_id
        LEFT JOIN profiles    p_creator  ON p_creator.id  = e.created_by
        LEFT JOIN employees   e_creator  ON e_creator.id  = p_creator.employee_id
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
    -- 13. picklist
    -- =========================================================================
    WHEN 'picklist' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT
          pl.id::text                                  AS "Picklist Id *",
          pv.ref_id                                    AS "Ref Id *",
          pv.value                                     AS "Value *",
          parent_pl.id::text                           AS "Parent Picklist Id",
          parent_pv.ref_id                             AS "Parent Ref Id",
          CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
          pv.meta::text                                AS "Meta"
        FROM picklist_values pv JOIN picklists pl ON pl.id=pv.picklist_id
        LEFT JOIN picklist_values parent_pv ON parent_pv.id=pv.parent_value_id
        LEFT JOIN picklists parent_pl ON parent_pl.id=parent_pv.picklist_id
        WHERE (p_include_inactive OR pv.active=true) ORDER BY pl.id, pv.ref_id) r;

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
  'Mig 408: complete column coverage for all 15 templates. '
  'System metadata (id, created_at, updated_at, etc.) filtered by Edge Function '
  'based on include_with_system_metadata flag in schema_definition. '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 4 — schema_definition updates for all templates
-- =============================================================================

-- Helper macro: sm = include_with_system_metadata column
-- uft = user_fillable true, uff = user_fillable false

-- 1. personal_info
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *',   'data_type','code_employee',        'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','First Name *',    'data_type','text',          'mandatory',true, 'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Last Name *',     'data_type','text',          'mandatory',true, 'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Middle Name',     'data_type','text',          'mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Preferred Name',  'data_type','text',          'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','Gender',          'data_type','text',          'mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','Date of Birth',   'data_type','date_mmddyyyy', 'mandatory',false,'user_fillable',true), 8
    UNION ALL SELECT jsonb_build_object('name','Nationality (ISO3)','data_type','text',        'mandatory',false,'user_fillable',true), 9
    UNION ALL SELECT jsonb_build_object('name','Marital Status',  'data_type','picklist:MARITAL_STATUS','mandatory',false,'user_fillable',true), 10
    UNION ALL SELECT jsonb_build_object('name','Slice End',       'data_type','date_mmddyyyy', 'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11
    UNION ALL SELECT jsonb_build_object('name','Slice Is Active', 'data_type','boolean',       'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12
    UNION ALL SELECT jsonb_build_object('name','id',              'data_type','uuid',           'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13
    UNION ALL SELECT jsonb_build_object('name','Created At',      'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 14
    UNION ALL SELECT jsonb_build_object('name','Updated At',      'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15
    UNION ALL SELECT jsonb_build_object('name','Inactive At',     'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='personal_info';

-- 2. contact_info
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Personal Email','data_type','text','mandatory',false,'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Country Code',  'data_type','text','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Mobile',        'data_type','text','mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='contact_info';

-- 3. address
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *','data_type','code_employee','mandatory',true,'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Line 1',       'data_type','text','mandatory',false,'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Line 2',       'data_type','text','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Landmark',     'data_type','text','mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','City',         'data_type','text','mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','District',     'data_type','text','mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','State',        'data_type','text','mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','Postal Code',  'data_type','text','mandatory',false,'user_fillable',true), 8
    UNION ALL SELECT jsonb_build_object('name','Country (ISO3)','data_type','text','mandatory',false,'user_fillable',true), 9
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='address';

-- 4. passport
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *',  'data_type','code_employee',       'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Passport Number *','data_type','text',      'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Country (ISO3)',   'data_type','picklist:ID_COUNTRY','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Issue Date',       'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Expiry Date',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='passport';

-- 5. identification
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *','data_type','code_employee',      'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','ID Type *',    'data_type','picklist:ID_TYPE',   'mandatory',true, 'user_fillable',true,'description','ID type label or ref_id'), 2
    UNION ALL SELECT jsonb_build_object('name','ID Number *',  'data_type','text',               'mandatory',true, 'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Record Type',  'data_type','text',               'mandatory',false,'user_fillable',true,'description','e.g. National, Passport, Driver'), 4
    UNION ALL SELECT jsonb_build_object('name','Country (ISO3)','data_type','picklist:ID_COUNTRY','mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Expiry Date',  'data_type','date_mmddyyyy',      'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='identification';

-- 6. emergency_contact
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *', 'data_type','code_employee',            'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Contact Name *','data_type','text',             'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Relationship',  'data_type','picklist:RELATIONSHIP_TYPE','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Phone',         'data_type','text',             'mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Alt Phone',     'data_type','text',             'mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Email',         'data_type','text',             'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='emergency_contact';

-- 7. employment
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Effective Date *',      'data_type','date_mmddyyyy',       'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Employee Code *',     'data_type','code_employee',       'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Designation',         'data_type','picklist:DESIGNATION','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Job Title',           'data_type','text',                'mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Department Code',     'data_type','code_department',     'mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Manager Employee Code','data_type','code_employee',      'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','Hire Date',           'data_type','date_mmddyyyy',       'mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','End Date',            'data_type','date_mmddyyyy',       'mandatory',false,'user_fillable',true), 8
    UNION ALL SELECT jsonb_build_object('name','Work Country (ISO3)', 'data_type','picklist:WORK_COUNTRY','mandatory',false,'user_fillable',true), 9
    UNION ALL SELECT jsonb_build_object('name','Work Location',       'data_type','picklist:LOCATION',   'mandatory',false,'user_fillable',true), 10
    UNION ALL SELECT jsonb_build_object('name','Base Currency',       'data_type','text',                'mandatory',false,'user_fillable',true), 11
    UNION ALL SELECT jsonb_build_object('name','Status',              'data_type','text',                'mandatory',false,'user_fillable',true), 12
    UNION ALL SELECT jsonb_build_object('name','Slice End',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13
    UNION ALL SELECT jsonb_build_object('name','Slice Is Active','data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 14
    UNION ALL SELECT jsonb_build_object('name','id',            'data_type','uuid',           'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15
    UNION ALL SELECT jsonb_build_object('name','Created At',    'data_type','timestamp',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16
    UNION ALL SELECT jsonb_build_object('name','Updated At',    'data_type','timestamp',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 17
    UNION ALL SELECT jsonb_build_object('name','Inactive At',   'data_type','timestamp',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 18
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='employment';

-- 8. job_relationships
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Effective Date *',    'data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Employee Code *',   'data_type','code_employee', 'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Relationship Code *','data_type','text',          'mandatory',true, 'user_fillable',true,'description','e.g. PM01, OM02'), 3
    UNION ALL SELECT jsonb_build_object('name','Value *',           'data_type','code_employee', 'mandatory',true, 'user_fillable',true,'description','Manager employee code'), 4
    UNION ALL SELECT jsonb_build_object('name','Slice End',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5
    UNION ALL SELECT jsonb_build_object('name','Slice Is Active','data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6
    UNION ALL SELECT jsonb_build_object('name','id',            'data_type','uuid',          'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    UNION ALL SELECT jsonb_build_object('name','Created At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8
    UNION ALL SELECT jsonb_build_object('name','Updated At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='job_relationships';

-- 9. dependents
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Effective Date *',  'data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Employee Code *',  'data_type','code_employee','mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Dependent Code *', 'data_type','text',         'mandatory',true, 'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Dependent Name *', 'data_type','text',         'mandatory',true, 'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Relationship *',   'data_type','picklist:DEPENDENT_RELATIONSHIP_TYPE','mandatory',true,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Gender',           'data_type','text',         'mandatory',false,'user_fillable',true,'description','Male or Female'), 6
    UNION ALL SELECT jsonb_build_object('name','Date of Birth',    'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','Insurance Eligible','data_type','yesno',       'mandatory',false,'user_fillable',true,'description','Yes or No'), 8
    UNION ALL SELECT jsonb_build_object('name','Slice End',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9
    UNION ALL SELECT jsonb_build_object('name','Slice Is Active','data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 10
    UNION ALL SELECT jsonb_build_object('name','id',            'data_type','uuid',          'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 11
    UNION ALL SELECT jsonb_build_object('name','Created At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 12
    UNION ALL SELECT jsonb_build_object('name','Updated At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 13
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='dependents';

-- 10. bank_accounts
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Effective Date *',       'data_type','date_mmddyyyy','mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Employee Code *',      'data_type','code_employee','mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Account Group Id *',   'data_type','text',         'mandatory',true, 'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Country (ISO3) *',     'data_type','text',         'mandatory',true, 'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Currency Code *',      'data_type','text',         'mandatory',true, 'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Bank Name *',          'data_type','text',         'mandatory',true, 'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','Branch Name',          'data_type','text',         'mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','Branch Code',          'data_type','text',         'mandatory',false,'user_fillable',true), 8
    UNION ALL SELECT jsonb_build_object('name','Account Holder Name *','data_type','text',         'mandatory',true, 'user_fillable',true), 9
    UNION ALL SELECT jsonb_build_object('name','Account Number *',     'data_type','text',         'mandatory',true, 'user_fillable',true), 10
    UNION ALL SELECT jsonb_build_object('name','IFSC Code',            'data_type','text',         'mandatory',false,'user_fillable',true), 11
    UNION ALL SELECT jsonb_build_object('name','IBAN',                 'data_type','text',         'mandatory',false,'user_fillable',true), 12
    UNION ALL SELECT jsonb_build_object('name','SWIFT / BIC',          'data_type','text',         'mandatory',false,'user_fillable',true), 13
    UNION ALL SELECT jsonb_build_object('name','Is Primary',           'data_type','yesno',        'mandatory',false,'user_fillable',true), 14
    UNION ALL SELECT jsonb_build_object('name','Slice End',      'data_type','date_mmddyyyy','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 15
    UNION ALL SELECT jsonb_build_object('name','Slice Is Active','data_type','boolean',      'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 16
    UNION ALL SELECT jsonb_build_object('name','id',            'data_type','uuid',          'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 17
    UNION ALL SELECT jsonb_build_object('name','Created At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 18
    UNION ALL SELECT jsonb_build_object('name','Updated At',    'data_type','timestamp',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 19
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='bank_accounts';

-- 11. employees
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Employee Code *',      'data_type','code_employee',        'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Full Name *',           'data_type','text',                 'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Business Email',        'data_type','text',                 'mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Designation',           'data_type','picklist:DESIGNATION', 'mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Job Title',             'data_type','text',                 'mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','Department Code',       'data_type','code_department',      'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','Manager Employee Code', 'data_type','code_employee',        'mandatory',false,'user_fillable',true), 7
    UNION ALL SELECT jsonb_build_object('name','Hire Date',             'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true), 8
    UNION ALL SELECT jsonb_build_object('name','End Date',              'data_type','date_mmddyyyy',        'mandatory',false,'user_fillable',true), 9
    UNION ALL SELECT jsonb_build_object('name','Work Country (ISO3)',   'data_type','picklist:WORK_COUNTRY','mandatory',false,'user_fillable',true), 10
    UNION ALL SELECT jsonb_build_object('name','Work Location',         'data_type','picklist:LOCATION',    'mandatory',false,'user_fillable',true), 11
    UNION ALL SELECT jsonb_build_object('name','Base Currency',         'data_type','text',                 'mandatory',false,'user_fillable',true), 12
    UNION ALL SELECT jsonb_build_object('name','Status',                'data_type','text',                 'mandatory',false,'user_fillable',true), 13
    UNION ALL SELECT jsonb_build_object('name','PM01 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Project Manager'), 14
    UNION ALL SELECT jsonb_build_object('name','PM02 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Programme Manager'), 15
    UNION ALL SELECT jsonb_build_object('name','PM03 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Practice Manager'), 16
    UNION ALL SELECT jsonb_build_object('name','OM01 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Manager'), 17
    UNION ALL SELECT jsonb_build_object('name','OM02 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Lead'), 18
    UNION ALL SELECT jsonb_build_object('name','OM03 Manager','data_type','code_employee','mandatory',false,'user_fillable',true,'description','Operations Coordinator'), 19
    UNION ALL SELECT jsonb_build_object('name','id',                  'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 20
    UNION ALL SELECT jsonb_build_object('name','Submitted At',        'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 21
    UNION ALL SELECT jsonb_build_object('name','Invite Sent At',      'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 22
    UNION ALL SELECT jsonb_build_object('name','Invite Accepted At',  'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 23
    UNION ALL SELECT jsonb_build_object('name','Locked',              'data_type','boolean',  'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 24
    UNION ALL SELECT jsonb_build_object('name','Created By',          'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 25
    UNION ALL SELECT jsonb_build_object('name','Created At',          'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 26
    UNION ALL SELECT jsonb_build_object('name','Updated At',          'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 27
    UNION ALL SELECT jsonb_build_object('name','Deleted At',          'data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 28
    ORDER BY ord
  ) t),
  'row_processor', 'per_row',
  'natural_key',   jsonb_build_array('Employee Code *')
), updated_at=NOW() WHERE template_code='employees';

-- 12. department
UPDATE bulk_template_registry SET schema_definition = jsonb_build_object(
  'columns', (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Department Code *',     'data_type','text',           'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Department Name *',    'data_type','text',           'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Parent Department Code','data_type','code_department','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Head Employee Code',   'data_type','code_employee',  'mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','Start Date',           'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true), 5
    UNION ALL SELECT jsonb_build_object('name','End Date',             'data_type','date_mmddyyyy',  'mandatory',false,'user_fillable',true), 6
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 8
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 9
    ORDER BY ord
  ) t),
  'row_processor', 'per_row',
  'natural_key',   jsonb_build_array('Department Code *')
), updated_at=NOW() WHERE template_code='department';

-- 13. project
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','Project Name *','data_type','text',        'mandatory',true, 'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','Start Date',  'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','End Date',    'data_type','date_mmddyyyy','mandatory',false,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Active',      'data_type','yesno',        'mandatory',false,'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='project';

-- 14. exchange_rate
UPDATE bulk_template_registry SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(col) FROM (
    SELECT jsonb_build_object('name','From Currency *','data_type','text',        'mandatory',true,'user_fillable',true) AS col, 1 AS ord
    UNION ALL SELECT jsonb_build_object('name','To Currency *',  'data_type','text',        'mandatory',true, 'user_fillable',true), 2
    UNION ALL SELECT jsonb_build_object('name','Effective Date *','data_type','date_mmddyyyy','mandatory',true,'user_fillable',true), 3
    UNION ALL SELECT jsonb_build_object('name','Rate *',         'data_type','text',        'mandatory',true, 'user_fillable',true), 4
    UNION ALL SELECT jsonb_build_object('name','id',        'data_type','uuid',     'mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 5
    UNION ALL SELECT jsonb_build_object('name','Created At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 6
    UNION ALL SELECT jsonb_build_object('name','Updated At','data_type','timestamp','mandatory',false,'user_fillable',false,'include_with_system_metadata',true), 7
    ORDER BY ord
  ) t)
), updated_at=NOW() WHERE template_code='exchange_rate';

-- =============================================================================
-- END OF MIGRATION 408
-- =============================================================================
