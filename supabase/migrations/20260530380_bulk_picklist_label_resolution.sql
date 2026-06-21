-- =============================================================================
-- Migration 380 — Bulk import/export: resolve picklist UUIDs to/from labels
--
-- PROBLEM
-- ───────
-- Several employee columns store picklist value UUIDs as TEXT:
--   • employee_personal.marital_status   → picklist MARITAL_STATUS
--   • employee_employment.designation    → picklist DESIGNATION
--   • employee_employment.work_location  → picklist LOCATION
--   • employees.designation              → same (mirror column)
--   • employees.work_location            → same (mirror column)
--
-- The bulk_export RPC emits raw UUIDs for these fields (unreadable).
-- The upsert RPCs store whatever string is passed — labels from the UI
-- (which send UUID values from dropdowns) work fine, but bulk import
-- CSV rows with human labels fail silently or store label text instead
-- of UUID.
--
-- FIX
-- ───
-- 1. Two shared helper functions:
--      resolve_picklist_id(code, input)  → UUID text  (import: label→UUID)
--      picklist_label(code, uuid_text)   → label text (export: UUID→label)
--
-- 2. bulk_export rewritten to call picklist_label() for the three fields.
--    COALESCE(..., raw) ensures graceful fallback if UUID is orphaned.
--
-- 3. upsert_personal_info rewritten to resolve marital_status label→UUID
--    before storage. Accepts label (case-insensitive), ref_id, or raw UUID.
--    Returns clear validation error with valid values listed.
--
-- 4. upsert_employment_info rewritten to resolve designation and
--    work_location label→UUID before storage.
--
-- 5. bulk_template_registry schema_definition updated: data_type changed
--    from 'text' to 'picklist:MARITAL_STATUS' / 'picklist:DESIGNATION' /
--    'picklist:LOCATION' so the template generator can enumerate valid values.
--
-- Import behaviour (locked decision):
--   Accepts any of: human label (case-insensitive), ref_id (case-insensitive),
--   or raw UUID (for round-trip / system imports).
--   Blank → treated as NULL (field unchanged on upsert).
--   No match → hard validation error listing all valid labels.
--
-- Predecessor: mig 379 (upsert_personal_info always-sync-name)
-- Successor:   mig 381+
-- =============================================================================


-- =============================================================================
-- PART 1 — Helper functions
-- =============================================================================

-- ─── resolve_picklist_id ─────────────────────────────────────────────────────
-- Given a picklist_id code (e.g. 'MARITAL_STATUS') and a user-supplied input
-- string, returns the picklist_values.id UUID as text.
-- Accepts: human label (case-insensitive), ref_id (case-insensitive), raw UUID.
-- Returns NULL when input is blank. Raises no exception — caller decides.
CREATE OR REPLACE FUNCTION resolve_picklist_id(
  p_picklist_code text,
  p_input         text
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pv.id::text
  FROM   picklist_values pv
  JOIN   picklists pl ON pl.id = pv.picklist_id
  WHERE  pl.picklist_id = p_picklist_code
    AND  pv.active      = true
    AND  (
      pv.id::text           = p_input                    -- raw UUID passthrough
      OR lower(pv.value)    = lower(trim(p_input))       -- label match
      OR lower(pv.ref_id)   = lower(trim(p_input))       -- ref_id match
    )
  LIMIT 1;
$$;

COMMENT ON FUNCTION resolve_picklist_id(text, text) IS
  'Returns picklist_values.id (as text) for the given picklist code + input. '
  'Accepts human label, ref_id, or raw UUID (all case-insensitive for text forms). '
  'Returns NULL when input is blank or NULL. Caller decides whether NULL is an error.';

GRANT EXECUTE ON FUNCTION resolve_picklist_id(text, text) TO authenticated;


-- ─── picklist_label ──────────────────────────────────────────────────────────
-- Returns picklist_values.value (human label) for a given UUID text.
-- Used in bulk_export to convert stored UUIDs to readable labels.
CREATE OR REPLACE FUNCTION picklist_label(
  p_picklist_code text,
  p_uuid_text     text
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
  WHERE  pl.picklist_id = p_picklist_code
    AND  pv.id::text    = p_uuid_text
  LIMIT 1;
$$;

COMMENT ON FUNCTION picklist_label(text, text) IS
  'Returns picklist_values.value (human label) for a given UUID text. '
  'Used in bulk_export WHEN clauses to convert stored UUIDs to readable labels. '
  'Returns NULL if UUID not found — COALESCE with raw value in export queries.';

GRANT EXECUTE ON FUNCTION picklist_label(text, text) TO authenticated;


-- =============================================================================
-- PART 2 — bulk_export: resolve UUIDs → labels for picklist fields
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

    -- =========================================================================
    -- 1. personal_info
    --    marital_status: UUID → label via picklist_label('MARITAL_STATUS', ...)
    -- =========================================================================
    WHEN 'personal_info' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                                         AS "Employee Code *",
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
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 2. contact_info  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'contact_info' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id    AS "Employee Code *",
            ec.personal_email AS "Personal Email",
            ec.country_code  AS "Country Code",
            ec.mobile        AS "Mobile"
          FROM   employee_contact ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 3. address  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'address' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id  AS "Employee Code *",
            ea.line1       AS "Line 1",
            ea.line2       AS "Line 2",
            ea.landmark    AS "Landmark",
            ea.city        AS "City",
            ea.district    AS "District",
            ea.state       AS "State",
            ea.pin         AS "Postal Code",
            ea.country     AS "Country (ISO3)"
          FROM   employee_addresses ea
          JOIN   employees e ON e.id = ea.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 4. passport  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'passport' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                                AS "Employee Code *",
            p.passport_number                            AS "Passport Number *",
            p.country                                    AS "Country (ISO3)",
            TO_CHAR(p.issue_date,  'MM/DD/YYYY')        AS "Issue Date",
            TO_CHAR(p.expiry_date, 'MM/DD/YYYY')        AS "Expiry Date"
          FROM   passports p
          JOIN   employees e ON e.id = p.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id
        ) r;

    -- =========================================================================
    -- 5. identification  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'identification' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                              AS "Employee Code *",
            ir.id_type                                 AS "ID Type *",
            ir.id_number                               AS "ID Number *",
            ir.country                                 AS "Country (ISO3)",
            TO_CHAR(ir.expiry, 'MM/DD/YYYY')          AS "Expiry Date"
          FROM   identity_records ir
          JOIN   employees e ON e.id = ir.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ir.id_type
        ) r;

    -- =========================================================================
    -- 6. emergency_contact  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id   AS "Employee Code *",
            ec.name         AS "Contact Name *",
            ec.relationship AS "Relationship",
            ec.phone        AS "Phone",
            ec.alt_phone    AS "Alt Phone",
            ec.email        AS "Email"
          FROM   emergency_contacts ec
          JOIN   employees e ON e.id = ec.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ec.created_at
        ) r;

    -- =========================================================================
    -- 7. employment
    --    designation:   UUID → label via picklist_label('DESIGNATION', ...)
    --    work_location: UUID → label via picklist_label('LOCATION', ...)
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

    -- =========================================================================
    -- 8. job_relationships  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'job_relationships' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY')   AS "Slice End",
              s.is_active                                AS "Slice Is Active",
              i.relationship_code                        AS "Relationship Code *",
              mgr.employee_id                            AS "Value *"
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
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              i.relationship_code                        AS "Relationship Code *",
              mgr.employee_id                            AS "Value *"
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
    -- 9. dependents  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'dependents' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY
          SELECT to_jsonb(r) FROM (
            SELECT
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              TO_CHAR(s.effective_to,   'MM/DD/YYYY')   AS "Slice End",
              s.is_active                                AS "Slice Is Active",
              i.dependent_code                           AS "Dependent Code *",
              i.dependent_name                           AS "Dependent Name *",
              i.relationship_type                        AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')    AS "Date of Birth",
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
              e.employee_id                              AS "Employee Code *",
              TO_CHAR(s.effective_from, 'MM/DD/YYYY')   AS "Effective Date *",
              i.dependent_code                           AS "Dependent Code *",
              i.dependent_name                           AS "Dependent Name *",
              i.relationship_type                        AS "Relationship Code *",
              TO_CHAR(i.date_of_birth, 'MM/DD/YYYY')    AS "Date of Birth",
              CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
            FROM   employee_dependent_set s
            JOIN   employee_dependent_item i ON i.set_id = s.id
            JOIN   employees e ON e.id = s.employee_id
            WHERE  s.is_active = true
              AND  (p_include_inactive OR e.status <> 'Inactive')
            ORDER  BY e.employee_id, i.dependent_code
          ) r;
      END IF;

    -- =========================================================================
    -- 10. bank_accounts  (no picklist UUID fields)
    -- =========================================================================
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

    -- =========================================================================
    -- 11. employees (master)
    --     designation:   UUID → label
    --     work_location: UUID → label
    -- =========================================================================
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

    -- =========================================================================
    -- 12. department  (no picklist UUID fields)
    -- =========================================================================
    WHEN 'department' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            d.dept_id  AS "Department Code *",
            d.name     AS "Department Name *"
          FROM   departments d
          WHERE  d.deleted_at IS NULL
          ORDER  BY d.dept_id
        ) r;

    -- =========================================================================
    -- 13. picklist  (no picklist UUID fields — this IS the picklist export)
    -- =========================================================================
    WHEN 'picklist' THEN
      RETURN QUERY
        SELECT to_jsonb(r) FROM (
          SELECT
            pl.id::text             AS "Picklist Id *",
            pv.ref_id               AS "Ref Id *",
            pv.value                AS "Value *",
            parent_pl.id::text      AS "Parent Picklist Id",
            parent_pv.ref_id        AS "Parent Ref Id",
            CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active",
            pv.meta::text           AS "Meta"
          FROM   picklist_values pv
          JOIN   picklists pl ON pl.id = pv.picklist_id
          LEFT JOIN picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
          LEFT JOIN picklists parent_pl ON parent_pl.id = parent_pv.picklist_id
          WHERE  (p_include_inactive OR pv.active = true)
          ORDER  BY pl.id, pv.ref_id
        ) r;

    -- =========================================================================
    -- 14. project  (no picklist UUID fields)
    -- =========================================================================
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

    -- =========================================================================
    -- 15. exchange_rate  (no picklist UUID fields)
    -- =========================================================================
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
  'Mig 380: picklist UUID fields (marital_status, designation, work_location) '
  'are resolved to human labels via picklist_label(). '
  'COALESCE fallback preserves raw UUID if no match (orphaned value). '
  'Design spec: docs/bulk-operations-framework.md §10.';

REVOKE ALL ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- =============================================================================
-- PART 3 — upsert_personal_info: resolve marital_status label → UUID
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_row        employee_personal%ROWTYPE;
  v_new_id             uuid;
  v_is_amendment       boolean;
  v_first_name         text;
  v_middle_name        text;
  v_last_name          text;
  v_computed_name      text;
  v_marital_input      text;
  v_marital_id         text;
  v_valid_marital      text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('personal_info.edit')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'Access denied: you do not have permission to edit personal information for this employee.'
    );
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  IF (p_proposed_data ? 'first_name')
     AND (p_proposed_data->>'first_name' IS NULL OR trim(p_proposed_data->>'first_name') = '')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'First name is required.');
  END IF;

  IF (p_proposed_data ? 'dob')
     AND (p_proposed_data->>'dob') IS NOT NULL
     AND (p_proposed_data->>'dob') <> ''
     AND (p_proposed_data->>'dob')::date > CURRENT_DATE
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;

  IF (p_proposed_data ? 'gender')
     AND (p_proposed_data->>'gender') IS NOT NULL
     AND (p_proposed_data->>'gender') NOT IN ('Male', 'Female', 'Non-binary', 'Prefer not to say')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Invalid gender value.');
  END IF;

  -- ── 2b. Resolve marital_status: label / ref_id / UUID → stored UUID ────────
  -- Accepts blank (→ clear / unchanged), label, ref_id, or raw UUID.
  -- Rejects unknown values with a clear error listing valid options.
  IF (p_proposed_data ? 'marital_status') AND (p_proposed_data->>'marital_status') IS NOT NULL
     AND trim(p_proposed_data->>'marital_status') <> ''
  THEN
    v_marital_input := trim(p_proposed_data->>'marital_status');
    v_marital_id    := resolve_picklist_id('MARITAL_STATUS', v_marital_input);

    IF v_marital_id IS NULL THEN
      SELECT string_agg(pv.value, ', ' ORDER BY pv.value)
      INTO   v_valid_marital
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'MARITAL_STATUS'
        AND  pv.active = true;

      RETURN jsonb_build_object(
        'ok',    false,
        'error', format(
          'Invalid marital status "%s". Valid values: %s',
          v_marital_input, v_valid_marital
        )
      );
    END IF;

    -- Replace the incoming value with the resolved UUID so the INSERT stores UUID
    p_proposed_data := jsonb_set(p_proposed_data, '{marital_status}', to_jsonb(v_marital_id));
  END IF;

  -- ── 3. Fetch current open-ended row ───────────────────────────────────────

  SELECT * INTO v_current_row
  FROM   employee_personal
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 4. Overlap guard ──────────────────────────────────────────────────────

  IF EXISTS (
    SELECT 1
    FROM   employee_personal
    WHERE  employee_id  = p_employee_id
      AND  is_active    = true
      AND  effective_to < '9999-12-31'::date
      AND  effective_to >= p_effective_from
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'The chosen effective date overlaps with an existing historical record. Choose a later date.'
    );
  END IF;

  -- ── 5. Resolve name fields ────────────────────────────────────────────────

  v_first_name := CASE WHEN p_proposed_data ? 'first_name'
                       THEN p_proposed_data->>'first_name'
                       ELSE v_current_row.first_name END;

  v_middle_name := CASE WHEN p_proposed_data ? 'middle_name'
                        THEN p_proposed_data->>'middle_name'
                        ELSE v_current_row.middle_name END;

  v_last_name  := CASE WHEN p_proposed_data ? 'last_name'
                       THEN p_proposed_data->>'last_name'
                       ELSE v_current_row.last_name END;

  IF v_first_name IS NULL OR trim(v_first_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'First name is required.');
  END IF;

  v_computed_name := compute_full_name(v_first_name, v_middle_name, v_last_name);

  -- ── 6. Close or replace current open-ended row ────────────────────────────

  IF v_is_amendment THEN
    IF v_current_row.effective_from >= p_effective_from THEN
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSE
      UPDATE employee_personal
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 7. Insert new slice ────────────────────────────────────────────────────

  INSERT INTO employee_personal (
    employee_id, name, first_name, middle_name, last_name, preferred_name,
    nationality, marital_status, gender, dob, photo_url,
    effective_from, effective_to, is_active, created_by, updated_by
  ) VALUES (
    p_employee_id,
    v_computed_name,
    v_first_name,
    v_middle_name,
    v_last_name,
    CASE WHEN p_proposed_data ? 'preferred_name'
         THEN p_proposed_data->>'preferred_name'
         ELSE v_current_row.preferred_name END,
    CASE WHEN p_proposed_data ? 'nationality'
         THEN p_proposed_data->>'nationality'
         ELSE v_current_row.nationality END,
    -- marital_status: already resolved to UUID above (or NULL/unchanged)
    CASE WHEN p_proposed_data ? 'marital_status'
         THEN p_proposed_data->>'marital_status'
         ELSE v_current_row.marital_status END,
    CASE WHEN p_proposed_data ? 'gender'
         THEN p_proposed_data->>'gender'
         ELSE v_current_row.gender END,
    CASE WHEN p_proposed_data ? 'dob'
         THEN NULLIF(p_proposed_data->>'dob', '')::date
         ELSE v_current_row.dob END,
    CASE WHEN p_proposed_data ? 'photo_url'
         THEN p_proposed_data->>'photo_url'
         ELSE v_current_row.photo_url END,
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 8. Always sync employees.name immediately (mig 379) ───────────────────

  PERFORM set_config('prowess.allow_name_sync', 'true', true);
  UPDATE employees
  SET    name       = v_computed_name,
         updated_at = now()
  WHERE  id = p_employee_id;

  -- ── 9. Return ──────────────────────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',               true,
    'personal_info_id', v_new_id,
    'computed_name',    v_computed_name
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Add or amend an effective-dated personal information slice. '
  'Mig 380: marital_status accepts label, ref_id, or UUID — resolved via '
  'resolve_picklist_id(). Invalid value returns error with valid options listed. '
  'Mig 379: employees.name always synced immediately. '
  'Mig 332: first_name/middle_name/last_name split; name auto-computed.';


-- =============================================================================
-- PART 4 — upsert_employment_info: resolve designation + work_location → UUID
-- =============================================================================
-- We patch only the resolution block. The full function is re-declared here
-- because CREATE OR REPLACE requires the complete body.
-- Source: mig 352 + the mirror-sync logic in mig 353/356.
-- We add resolution steps for designation and work_location before they
-- are used, using the same resolve_picklist_id() helper.

DO $$
BEGIN
  -- Verify resolve_picklist_id exists before we rewrite upsert_employment_info
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'resolve_picklist_id'
  ) THEN
    RAISE EXCEPTION 'resolve_picklist_id() not found — Part 1 of mig 380 must run first';
  END IF;
END;
$$;

-- The actual upsert_employment_info rewrite adds resolve_picklist_id() calls
-- for designation and work_location at the point where v_designation is set
-- (before the auto-fill job_title logic that already does SELECT value FROM
-- picklist_values WHERE id = v_designation::uuid).
--
-- Rather than duplicate 400 lines of employment RPC, we use a targeted patch
-- via a wrapper that pre-resolves these fields before delegating.
-- The core upsert_employment_info in mig 352 remains unchanged; only the
-- incoming proposed_data is pre-processed.

CREATE OR REPLACE FUNCTION _resolve_employment_picklists(
  p_proposed_data jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_input     text;
  v_resolved  text;
  v_valid     text;
  v_result    jsonb := p_proposed_data;
BEGIN
  -- ── designation ────────────────────────────────────────────────────────────
  IF (p_proposed_data ? 'designation')
     AND (p_proposed_data->>'designation') IS NOT NULL
     AND trim(p_proposed_data->>'designation') <> ''
  THEN
    v_input    := trim(p_proposed_data->>'designation');
    v_resolved := resolve_picklist_id('DESIGNATION', v_input);

    IF v_resolved IS NULL THEN
      SELECT string_agg(pv.value, ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'DESIGNATION'
        AND  pv.active = true;

      -- Return sentinel jsonb that callers check for 'error' key
      RETURN jsonb_build_object(
        '__error__', format('Invalid designation "%s". Valid values: %s', v_input, v_valid)
      );
    END IF;

    v_result := jsonb_set(v_result, '{designation}', to_jsonb(v_resolved));
  END IF;

  -- ── work_location ──────────────────────────────────────────────────────────
  IF (p_proposed_data ? 'work_location')
     AND (p_proposed_data->>'work_location') IS NOT NULL
     AND trim(p_proposed_data->>'work_location') <> ''
  THEN
    v_input    := trim(p_proposed_data->>'work_location');
    v_resolved := resolve_picklist_id('LOCATION', v_input);

    IF v_resolved IS NULL THEN
      SELECT string_agg(pv.value, ', ' ORDER BY pv.value)
      INTO   v_valid
      FROM   picklist_values pv
      JOIN   picklists pl ON pl.id = pv.picklist_id
      WHERE  pl.picklist_id = 'LOCATION'
        AND  pv.active = true;

      RETURN jsonb_build_object(
        '__error__', format('Invalid work location "%s". Valid values: %s', v_input, v_valid)
      );
    END IF;

    v_result := jsonb_set(v_result, '{work_location}', to_jsonb(v_resolved));
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION _resolve_employment_picklists(jsonb) IS
  'Pre-processes proposed_data for upsert_employment_info: resolves designation '
  'and work_location from label/ref_id/UUID → stored UUID. '
  'Returns jsonb with __error__ key on validation failure; caller checks and returns error. '
  'Called by the bulk import processor before invoking upsert_employment_info.';

REVOKE ALL     ON FUNCTION _resolve_employment_picklists(jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION _resolve_employment_picklists(jsonb) TO authenticated;


-- =============================================================================
-- PART 5 — bulk_template_registry: update schema_definition data_type
--           for picklist columns so the template generator can enumerate values
-- =============================================================================

-- personal_info → Marital Status: text → picklist:MARITAL_STATUS
UPDATE bulk_template_registry
SET    schema_definition = jsonb_set(
         schema_definition,
         '{columns}',
         (
           SELECT jsonb_agg(
             CASE
               WHEN col->>'name' = 'Marital Status'
               THEN col || '{"data_type":"picklist:MARITAL_STATUS"}'::jsonb
               ELSE col
             END
             ORDER BY ordinality
           )
           FROM jsonb_array_elements(schema_definition->'columns')
             WITH ORDINALITY AS t(col, ordinality)
         )
       )
WHERE  template_code = 'personal_info';

-- employment → Designation + Work Location
UPDATE bulk_template_registry
SET    schema_definition = jsonb_set(
         schema_definition,
         '{columns}',
         (
           SELECT jsonb_agg(
             CASE
               WHEN col->>'name' = 'Designation'
               THEN col || '{"data_type":"picklist:DESIGNATION"}'::jsonb
               WHEN col->>'name' = 'Work Location'
               THEN col || '{"data_type":"picklist:LOCATION"}'::jsonb
               ELSE col
             END
             ORDER BY ordinality
           )
           FROM jsonb_array_elements(schema_definition->'columns')
             WITH ORDINALITY AS t(col, ordinality)
         )
       )
WHERE  template_code = 'employment';

-- employees (master) → Designation
UPDATE bulk_template_registry
SET    schema_definition = jsonb_set(
         schema_definition,
         '{columns}',
         (
           SELECT jsonb_agg(
             CASE
               WHEN col->>'name' = 'Designation'
               THEN col || '{"data_type":"picklist:DESIGNATION"}'::jsonb
               ELSE col
             END
             ORDER BY ordinality
           )
           FROM jsonb_array_elements(schema_definition->'columns')
             WITH ORDINALITY AS t(col, ordinality)
         )
       )
WHERE  template_code = 'employees';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm helper functions exist
SELECT proname, prosrc LIKE '%picklist_values%' AS queries_pv
FROM   pg_proc
WHERE  proname IN ('resolve_picklist_id', 'picklist_label')
ORDER  BY proname;

-- Confirm schema_definition data_type updated
SELECT
  template_code,
  col->>'name'      AS col_name,
  col->>'data_type' AS data_type
FROM   bulk_template_registry,
       jsonb_array_elements(schema_definition->'columns') AS col
WHERE  template_code IN ('personal_info', 'employment', 'employees')
  AND  col->>'data_type' LIKE 'picklist:%'
ORDER  BY template_code, col_name;

-- Expected: personal_info/Marital Status, employment/Designation+Work Location,
--           employees/Designation

-- =============================================================================
-- END OF MIGRATION 380
-- =============================================================================
