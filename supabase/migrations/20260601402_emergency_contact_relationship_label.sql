-- =============================================================================
-- Migration 402 — Emergency contact bulk: resolve relationship to label
--
-- emergency_contacts.relationship stores a UUID from the RELATIONSHIP_TYPE
-- picklist. Export emits raw UUID; import stores whatever string is passed.
--
-- FIX
-- ───
-- 1. bulk_export WHEN 'emergency_contact': wrap relationship with picklist_label.
-- 2. upsert_emergency_contact: resolve label/ref_id/UUID → UUID on import.
-- 3. schema_definition data_type updated: 'text' → 'picklist:RELATIONSHIP_TYPE'.
-- =============================================================================


-- =============================================================================
-- PART 1 — upsert_emergency_contact: resolve relationship label → UUID
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  -- ── relationship: resolve label / ref_id / UUID → UUID (optional) ──────────
  v_relationship := NULL;
  IF NULLIF(p_row->>'relationship', '') IS NOT NULL THEN
    v_relationship := resolve_picklist_id('RELATIONSHIP_TYPE', trim(p_row->>'relationship'));
    IF v_relationship IS NULL THEN
      SELECT string_agg(pv.value || ' (' || pv.ref_id || ')', ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'RELATIONSHIP_TYPE' AND pv.active = true;
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'Unknown Relationship "' || (p_row->>'relationship') || '". Valid values: ' || COALESCE(v_valid, '(none)')
      );
    END IF;
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (
    p_employee_id,
    p_row->>'name',
    v_relationship,
    NULLIF(p_row->>'phone',     ''),
    NULLIF(p_row->>'alt_phone', ''),
    NULLIF(p_row->>'email',     '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = COALESCE(EXCLUDED.relationship,               emergency_contacts.relationship),
    phone        = COALESCE(NULLIF(EXCLUDED.phone,     ''),      emergency_contacts.phone),
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone, ''),      emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,     ''),      emergency_contacts.email),
    updated_at   = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_emergency_contact IS
  'Bulk-import processor for emergency_contact template. '
  'Accepts label, ref_id, or raw UUID for relationship (RELATIONSHIP_TYPE picklist). '
  'Upserts emergency_contacts (one per employee). Bypasses workflow.';

GRANT EXECUTE ON FUNCTION upsert_emergency_contact(UUID, JSONB) TO authenticated;


-- =============================================================================
-- PART 2 — bulk_export: resolve relationship UUID → label
--           Only the emergency_contact WHEN clause changes; all others carried
--           forward verbatim from mig 401.
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
  IF NOT user_can(p_template_code, 'bulk_export', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_export required', p_template_code
      USING ERRCODE = '42501';
  END IF;

  CASE p_template_code

    WHEN 'personal_info' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                                                         AS "Employee Code *",
              TO_CHAR(ep.effective_from, 'MM/DD/YYYY')                             AS "Effective Date *",
              TO_CHAR(ep.effective_to,   'MM/DD/YYYY')                             AS "Slice End",
              ep.is_active                                                          AS "Slice Is Active",
              ep.first_name                                                         AS "First Name *",
              ep.last_name                                                          AS "Last Name *",
              ep.middle_name                                                        AS "Middle Name",
              ep.gender                                                             AS "Gender",
              TO_CHAR(ep.dob, 'MM/DD/YYYY')                                        AS "Date of Birth",
              ep.nationality                                                        AS "Nationality (ISO3)",
              COALESCE(picklist_label('MARITAL_STATUS', ep.marital_status),
                       ep.marital_status)                                           AS "Marital Status"
            FROM   employee_personal ep
            JOIN   employees e ON e.id = ep.employee_id
            WHERE  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, ep.effective_from
          ) r;
      ELSE
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                                                         AS "Employee Code *",
              TO_CHAR(ep.effective_from, 'MM/DD/YYYY')                             AS "Effective Date *",
              ep.first_name                                                         AS "First Name *",
              ep.last_name                                                          AS "Last Name *",
              ep.middle_name                                                        AS "Middle Name",
              ep.gender                                                             AS "Gender",
              TO_CHAR(ep.dob, 'MM/DD/YYYY')                                        AS "Date of Birth",
              ep.nationality                                                        AS "Nationality (ISO3)",
              COALESCE(picklist_label('MARITAL_STATUS', ep.marital_status),
                       ep.marital_status)                                           AS "Marital Status"
            FROM   employee_personal ep
            JOIN   employees e ON e.id = ep.employee_id
            WHERE  ep.is_active    = true
              AND  ep.effective_to = '9999-12-31'::date
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id
          ) r;
      END IF;

    WHEN 'contact_info' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id     AS "Employee Code *",
            ec.personal_email AS "Personal Email",
            ec.country_code   AS "Country Code",
            ec.mobile         AS "Mobile"
          FROM   employee_contact ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    WHEN 'address' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id AS "Employee Code *",
            ea.line1      AS "Line 1",
            ea.line2      AS "Line 2",
            ea.landmark   AS "Landmark",
            ea.city       AS "City",
            ea.district   AS "District",
            ea.state      AS "State",
            ea.pin        AS "Postal Code",
            ea.country    AS "Country (ISO3)"
          FROM   employee_addresses ea
          JOIN   employees e ON e.id = ea.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    WHEN 'passport' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                           AS "Employee Code *",
            p.passport_number                                                       AS "Passport Number *",
            COALESCE(picklist_label('ID_COUNTRY', p.country), p.country)           AS "Country (ISO3)",
            TO_CHAR(p.issue_date,  'MM/DD/YYYY')                                   AS "Issue Date",
            TO_CHAR(p.expiry_date, 'MM/DD/YYYY')                                   AS "Expiry Date"
          FROM   passports p
          JOIN   employees e ON e.id = p.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    WHEN 'identification' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                          AS "Employee Code *",
            COALESCE(picklist_label('ID_TYPE',    ir.id_type),  ir.id_type)       AS "ID Type *",
            ir.id_number                                                           AS "ID Number *",
            COALESCE(picklist_label('ID_COUNTRY', ir.country),  ir.country)       AS "Country (ISO3)",
            TO_CHAR(ir.expiry, 'MM/DD/YYYY')                                      AS "Expiry Date"
          FROM   identity_records ir
          JOIN   employees e ON e.id = ir.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ir.id_type
        ) r;

    -- =========================================================================
    -- emergency_contact  ← FIXED: picklist_label for relationship
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                                    AS "Employee Code *",
            ec.name                                                                          AS "Contact Name *",
            COALESCE(picklist_label('RELATIONSHIP_TYPE', ec.relationship), ec.relationship) AS "Relationship",
            ec.phone                                                                         AS "Phone",
            ec.alt_phone                                                                     AS "Alt Phone",
            ec.email                                                                         AS "Email"
          FROM   emergency_contacts ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ec.created_at
        ) r;

    WHEN 'employment' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                                                           AS "Employee Code *",
              TO_CHAR(ee.effective_from, 'MM/DD/YYYY')                               AS "Effective Date *",
              TO_CHAR(ee.effective_to,   'MM/DD/YYYY')                               AS "Slice End",
              ee.is_active                                                            AS "Slice Is Active",
              COALESCE(picklist_label('DESIGNATION', ee.designation),
                       ee.designation)                                                AS "Designation",
              ee.job_title                                                            AS "Job Title",
              d.dept_id                                                               AS "Department Code",
              mgr.employee_id                                                         AS "Manager Employee Code",
              TO_CHAR(ee.hire_date, 'MM/DD/YYYY')                                    AS "Hire Date",
              TO_CHAR(ee.end_date,  'MM/DD/YYYY')                                    AS "End Date",
              ee.work_country                                                         AS "Work Country (ISO3)",
              COALESCE(picklist_label('LOCATION', ee.work_location),
                       ee.work_location)                                              AS "Work Location",
              c.code                                                                  AS "Base Currency",
              ee.status::text                                                         AS "Status"
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
              e.employee_id                                                           AS "Employee Code *",
              TO_CHAR(ee.effective_from, 'MM/DD/YYYY')                               AS "Effective Date *",
              COALESCE(picklist_label('DESIGNATION', ee.designation),
                       ee.designation)                                                AS "Designation",
              ee.job_title                                                            AS "Job Title",
              d.dept_id                                                               AS "Department Code",
              mgr.employee_id                                                         AS "Manager Employee Code",
              TO_CHAR(ee.hire_date, 'MM/DD/YYYY')                                    AS "Hire Date",
              TO_CHAR(ee.end_date,  'MM/DD/YYYY')                                    AS "End Date",
              ee.work_country                                                         AS "Work Country (ISO3)",
              COALESCE(picklist_label('LOCATION', ee.work_location),
                       ee.work_location)                                              AS "Work Location",
              c.code                                                                  AS "Base Currency",
              ee.status::text                                                         AS "Status"
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

    WHEN 'job_relationships' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                            AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY') AS "Slice End",
              s.is_active                              AS "Slice Is Active",
              i.relationship_code                      AS "Relationship Code *",
              mgr.employee_id                          AS "Value *"
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
              e.employee_id                            AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
              i.relationship_code                      AS "Relationship Code *",
              mgr.employee_id                          AS "Value *"
            FROM   employee_job_relationship_set s
            JOIN   employee_job_relationship_item i ON i.set_id = s.id
            JOIN   employees e   ON e.id   = s.employee_id
            JOIN   employees mgr ON mgr.id = i.manager_employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.relationship_code
          ) r;
      END IF;

    WHEN 'dependents' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                            AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY') AS "Slice End",
              s.is_active                              AS "Slice Is Active",
              i.dependent_code                         AS "Dependent Code *",
              i.dependent_name                         AS "Dependent Name *",
              i.relationship_type                      AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')  AS "Date of Birth",
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
              e.employee_id                            AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY') AS "Effective Date *",
              i.dependent_code                         AS "Dependent Code *",
              i.dependent_name                         AS "Dependent Name *",
              i.relationship_type                      AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')  AS "Date of Birth",
              CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
            FROM   employee_dependent_set s
            JOIN   employee_dependent_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.dependent_code
          ) r;
      END IF;

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

    WHEN 'employees' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                         AS "Employee Code *",
            e.name                                                                AS "Full Name *",
            e.business_email                                                      AS "Business Email",
            COALESCE(picklist_label('DESIGNATION', e.designation),
                     e.designation)                                               AS "Designation",
            e.job_title                                                           AS "Job Title",
            d.dept_id                                                             AS "Department Code",
            mgr.employee_id                                                       AS "Manager Employee Code",
            TO_CHAR(e.hire_date, 'MM/DD/YYYY')                                   AS "Hire Date",
            TO_CHAR(e.end_date,  'MM/DD/YYYY')                                   AS "End Date",
            e.status::text                                                        AS "Status"
          FROM   employees e
          LEFT JOIN departments d   ON d.id  = e.dept_id
          LEFT JOIN employees mgr   ON mgr.id = e.manager_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
            AND  e.status NOT IN ('Draft', 'Incomplete')
          ORDER  BY e.employee_id
        ) r;

    WHEN 'department' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT d.dept_id AS "Department Code *", d.name AS "Department Name *"
          FROM   departments d
          WHERE  d.deleted_at IS NULL
          ORDER  BY d.dept_id
        ) r;

    WHEN 'picklist' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            pl.id::text        AS "Picklist Id *",
            pv.ref_id          AS "Ref Id *",
            pv.value           AS "Value *",
            parent_pl.id::text AS "Parent Picklist Id",
            parent_pv.ref_id   AS "Parent Ref Id",
            CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
            pv.meta::text      AS "Meta"
          FROM   picklist_values pv
          JOIN   picklists pl ON pl.id = pv.picklist_id
          LEFT JOIN picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
          LEFT JOIN picklists parent_pl ON parent_pl.id = parent_pv.picklist_id
          WHERE  (p_include_inactive OR pv.active = true)
          ORDER  BY pl.id, pv.ref_id
        ) r;

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
  'Mig 402: emergency_contact relationship resolved to label (RELATIONSHIP_TYPE). '
  'Mig 401: identification id_type + country, passport country resolved to labels. '
  'Mig 381: personal_info includes Effective Date *. '
  'Mig 380: employment picklist fields resolved to labels. '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 3 — schema_definition: update Relationship data_type
-- =============================================================================

UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{columns}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN col->>'name' = 'Relationship'
          THEN col || jsonb_build_object('data_type', 'picklist:RELATIONSHIP_TYPE', 'description', 'Relationship label or ref_id, e.g. Spouse, Father, Mother')
        ELSE col
      END
    )
    FROM jsonb_array_elements(schema_definition->'columns') AS col
  )
),
updated_at = NOW()
WHERE template_code = 'emergency_contact';

-- =============================================================================
-- END OF MIGRATION 402
-- =============================================================================
