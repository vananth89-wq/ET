-- =============================================================================
-- Migration 403 — bulk_export: label resolution for employment work_country
--                 and dependents relationship_type
--
-- PROBLEMS
-- ────────
-- 1. employment WHEN clause: ee.work_country stores a UUID from the LOCATION
--    parent picklist. No named picklist_id — uses generic UUID lookup.
--    (Designation and work_location already resolved by mig 380/381.)
--
-- 2. dependents WHEN clause: i.relationship_type stores a ref_id string
--    (e.g. DR001) from DEPENDENT_RELATIONSHIP_TYPE picklist — NOT a UUID.
--    picklist_label() won't work here; need a ref_id-based lookup.
--
-- FIX
-- ───
-- 1. New helper: picklist_value_label(uuid_text)
--    Generic UUID → value lookup (no picklist_id filter). Used for work_country.
--
-- 2. New helper: picklist_label_by_ref(picklist_code, ref_id)
--    ref_id → value lookup. Used for dependents relationship_type.
--
-- 3. bulk_export WHEN clauses updated for employment and dependents.
--    All other WHEN clauses carried forward verbatim from mig 402.
-- =============================================================================


-- =============================================================================
-- PART 1 — Helper functions
-- =============================================================================

-- Generic UUID → label (no picklist_id filter — for columns like work_country
-- whose picklist_id isn't tracked in code)
CREATE OR REPLACE FUNCTION picklist_value_label(p_uuid_text text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT value FROM picklist_values WHERE id::text = p_uuid_text LIMIT 1;
$$;

COMMENT ON FUNCTION picklist_value_label(text) IS
  'Returns picklist_values.value for a given UUID text, without picklist_id filter. '
  'Use when the picklist_id code is not available (e.g. work_country). '
  'Returns NULL if not found.';

GRANT EXECUTE ON FUNCTION picklist_value_label(text) TO authenticated;


-- ref_id → label lookup (for columns that store ref_id not UUID)
CREATE OR REPLACE FUNCTION picklist_label_by_ref(
  p_picklist_code text,
  p_ref_id        text
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pv.value
  FROM   picklist_values pv
  JOIN   picklists pl ON pl.id = pv.picklist_id
  WHERE  pl.picklist_id    = p_picklist_code
    AND  lower(pv.ref_id)  = lower(trim(p_ref_id))
    AND  pv.active         = true
  LIMIT 1;
$$;

COMMENT ON FUNCTION picklist_label_by_ref(text, text) IS
  'Returns picklist_values.value for a given picklist code + ref_id. '
  'Used when columns store ref_id strings rather than UUIDs (e.g. dependent relationship_type). '
  'Returns NULL if not found.';

GRANT EXECUTE ON FUNCTION picklist_label_by_ref(text, text) TO authenticated;


-- =============================================================================
-- PART 2 — bulk_export: update employment and dependents WHEN clauses
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

    -- =========================================================================
    -- employment  ← FIXED: work_country UUID → label via picklist_value_label()
    -- =========================================================================
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
              COALESCE(picklist_value_label(ee.work_country), ee.work_country)        AS "Work Country (ISO3)",
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
              COALESCE(picklist_value_label(ee.work_country), ee.work_country)        AS "Work Country (ISO3)",
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

    -- =========================================================================
    -- dependents  ← FIXED: relationship_type ref_id → label via picklist_label_by_ref()
    -- =========================================================================
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
              COALESCE(picklist_label_by_ref('DEPENDENT_RELATIONSHIP_TYPE', i.relationship_type),
                       i.relationship_type)            AS "Relationship *",
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
              COALESCE(picklist_label_by_ref('DEPENDENT_RELATIONSHIP_TYPE', i.relationship_type),
                       i.relationship_type)            AS "Relationship *",
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
  'Mig 403: employment work_country UUID → label; dependents relationship_type ref_id → label. '
  'Mig 402: emergency_contact relationship UUID → label. '
  'Mig 401: identification id_type + country, passport country → labels. '
  'Mig 381: personal_info Effective Date *. Mig 380: employment designation + work_location → labels. '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 3 — schema_definition updates
-- =============================================================================

-- employment: Work Country column data_type
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(
      CASE WHEN col->>'name' = 'Work Country (ISO3)'
        THEN col || jsonb_build_object('data_type', 'picklist:WORK_COUNTRY', 'description', 'Work country label, e.g. India, United Kingdom')
        ELSE col
      END)
   FROM jsonb_array_elements(schema_definition->'columns') AS col)
), updated_at = NOW()
WHERE template_code = 'employment';

-- dependents: rename Relationship Code * → Relationship * and update data_type
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition, '{columns}',
  (SELECT jsonb_agg(
      CASE WHEN col->>'name' = 'Relationship Code *'
        THEN col || jsonb_build_object(
          'name',      'Relationship *',
          'data_type', 'picklist:DEPENDENT_RELATIONSHIP_TYPE',
          'description', 'Relationship label, e.g. Spouse, Son, Daughter'
        )
        ELSE col
      END)
   FROM jsonb_array_elements(schema_definition->'columns') AS col)
), updated_at = NOW()
WHERE template_code = 'dependents';

-- =============================================================================
-- END OF MIGRATION 403
-- =============================================================================
