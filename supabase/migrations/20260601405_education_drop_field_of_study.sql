-- =============================================================================
-- Migration 400 — Education: drop field_of_study column
--
-- field_of_study is removed from the education module.
-- Changes:
--   1. DROP column from employee_education
--   2. CREATE OR REPLACE upsert_education (remove v_field_of_study)
--   3. CREATE OR REPLACE bulk_export (remove field_of_study from education WHEN clause)
-- =============================================================================


-- =============================================================================
-- 1. Drop the column
-- =============================================================================

ALTER TABLE employee_education DROP COLUMN IF EXISTS field_of_study;


-- =============================================================================
-- 2. upsert_education — remove field_of_study
-- =============================================================================

DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid);

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              uuid  := auth.uid();
  v_is_path_a          boolean;
  v_edu_id             uuid;
  v_education_level    text;
  v_degree             text;
  v_institution        text;
  v_start_date         date;
  v_end_date           date;
  v_completion_status  text;
  v_grade_or_gpa       text;
  v_is_highest         boolean;
  v_att                jsonb;
  v_submit_result      jsonb;
BEGIN

  v_is_path_a := (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR (
      user_can('education', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

  IF NOT v_is_path_a AND NOT user_can('education', 'view', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  v_education_level   := p_education_data->>'education_level';
  v_degree            := NULLIF(trim(p_education_data->>'degree'),       '');
  v_institution       := NULLIF(trim(p_education_data->>'institution'),  '');
  v_start_date        := NULLIF(p_education_data->>'start_date', '')::date;
  v_end_date          := NULLIF(p_education_data->>'end_date',   '')::date;
  v_completion_status := p_education_data->>'completion_status';
  v_grade_or_gpa      := NULLIF(trim(p_education_data->>'grade_or_gpa'), '');
  v_is_highest        := COALESCE((p_education_data->>'is_highest_qualification')::boolean, false);

  IF v_education_level IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'education_level is required.');
  END IF;
  IF v_degree IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'degree is required.');
  END IF;
  IF v_institution IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'institution is required.');
  END IF;
  IF v_start_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'start_date is required.');
  END IF;
  IF v_completion_status IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'completion_status is required.');
  END IF;
  IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'end_date must be on or after start_date.');
  END IF;
  IF v_completion_status = 'ES01' THEN
    IF v_end_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date is required for Completed qualifications.');
    END IF;
    IF v_end_date > CURRENT_DATE THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date cannot be in the future for Completed qualifications.');
    END IF;
  END IF;

  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code   => 'profile_education',
      p_record_id     => p_education_id,
      p_proposed_data => p_education_data,
      p_action        => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END
    );
    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;
    RETURN jsonb_build_object(
      'ok',               true,
      'workflow',         true,
      'instance_id',      v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  IF v_is_highest THEN
    UPDATE employee_education
    SET    is_highest_qualification = false, updated_by = v_actor, updated_at = NOW()
    WHERE  employee_id              = p_employee_id
      AND  is_highest_qualification = true
      AND  is_active                = true
      AND  (p_education_id IS NULL OR id <> p_education_id);
  END IF;

  IF p_education_id IS NOT NULL THEN
    UPDATE employee_education
    SET
      education_level          = v_education_level,
      degree                   = v_degree,
      institution              = v_institution,
      start_date               = v_start_date,
      end_date                 = v_end_date,
      completion_status        = v_completion_status,
      grade_or_gpa             = v_grade_or_gpa,
      is_highest_qualification = v_is_highest,
      updated_by               = v_actor,
      updated_at               = NOW()
    WHERE id          = p_education_id
      AND employee_id = p_employee_id
      AND is_active   = true;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already removed.');
    END IF;
    v_edu_id := p_education_id;
  ELSE
    INSERT INTO employee_education (
      employee_id, education_level, degree, institution,
      start_date, end_date, completion_status, grade_or_gpa,
      is_highest_qualification, created_by, updated_by
    ) VALUES (
      p_employee_id, v_education_level, v_degree, v_institution,
      v_start_date, v_end_date, v_completion_status, v_grade_or_gpa,
      v_is_highest, v_actor, v_actor
    )
    RETURNING id INTO v_edu_id;
  END IF;

  IF p_education_data ? 'attachments' THEN
    FOR v_att IN SELECT * FROM jsonb_array_elements(p_education_data->'attachments')
    LOOP
      IF (v_att->>'_removed')::boolean IS TRUE AND (v_att->>'id') IS NOT NULL THEN
        UPDATE employee_education_attachments
        SET    is_active = false
        WHERE  id = (v_att->>'id')::uuid AND education_id = v_edu_id;
        CONTINUE;
      END IF;
      IF (v_att->>'id') IS NOT NULL AND (v_att->>'_removed') IS DISTINCT FROM 'true' THEN
        UPDATE employee_education_attachments
        SET    document_type = COALESCE(v_att->>'document_type', document_type)
        WHERE  id = (v_att->>'id')::uuid AND education_id = v_edu_id;
        CONTINUE;
      END IF;
      IF NULLIF(v_att->>'file_path', '') IS NULL THEN CONTINUE; END IF;
      INSERT INTO employee_education_attachments (
        education_id, employee_id, document_type,
        file_name, original_file_name, file_path,
        mime_type, file_size, uploaded_by, created_by
      ) VALUES (
        v_edu_id, p_employee_id, v_att->>'document_type',
        v_att->>'file_name',
        COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
        v_att->>'file_path',
        COALESCE(v_att->>'mime_type', 'application/octet-stream'),
        COALESCE((v_att->>'file_size')::bigint, 0),
        v_actor, v_actor
      );
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'workflow', false, 'education_id', v_edu_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_education(uuid, jsonb, uuid) IS
  'Add or edit a single employee_education row (field_of_study removed in mig 400). '
  'PATH A: direct write. PATH B: workflow staging. Mig 396 + mig 400.';

REVOKE ALL     ON FUNCTION upsert_education(uuid, jsonb, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid) TO authenticated;


-- =============================================================================
-- 3. bulk_export — remove field_of_study from education WHEN clause
--    Only the education clause changes; all 15 other clauses are unchanged.
--    Postgres requires the full body on CREATE OR REPLACE.
--    (Full body reproduced from mig 398 minus field_of_study.)
-- =============================================================================

DROP FUNCTION IF EXISTS bulk_export(TEXT, BOOLEAN, TEXT);

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
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", ep.first_name AS "First Name *", ep.last_name AS "Last Name *",
               ep.middle_name AS "Middle Name", ep.gender AS "Gender", TO_CHAR(ep.dob,'MM/DD/YYYY') AS "Date of Birth",
               ep.nationality AS "Nationality (ISO3)", ep.marital_status AS "Marital Status"
        FROM employee_personal ep JOIN employees e ON e.id = ep.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id
      ) r;

    WHEN 'contact_info' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", ec.personal_email AS "Personal Email",
               ec.country_code AS "Country Code", ec.mobile AS "Mobile"
        FROM employee_contact ec JOIN employees e ON e.id = ec.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id
      ) r;

    WHEN 'address' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", ea.line1 AS "Line 1", ea.line2 AS "Line 2",
               ea.landmark AS "Landmark", ea.city AS "City", ea.district AS "District",
               ea.state AS "State", ea.pin AS "Postal Code", ea.country AS "Country (ISO3)"
        FROM employee_addresses ea JOIN employees e ON e.id = ea.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id
      ) r;

    WHEN 'passport' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", p.passport_number AS "Passport Number *",
               p.country AS "Country (ISO3)", TO_CHAR(p.issue_date,'MM/DD/YYYY') AS "Issue Date",
               TO_CHAR(p.expiry_date,'MM/DD/YYYY') AS "Expiry Date"
        FROM passports p JOIN employees e ON e.id = p.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id
      ) r;

    WHEN 'identification' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", ir.id_type AS "ID Type *", ir.id_number AS "ID Number *",
               ir.country AS "Country (ISO3)", TO_CHAR(ir.expiry,'MM/DD/YYYY') AS "Expiry Date"
        FROM identity_records ir JOIN employees e ON e.id = ir.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id, ir.id_type
      ) r;

    WHEN 'emergency_contact' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", ec.name AS "Contact Name *", ec.relationship AS "Relationship",
               ec.phone AS "Phone", ec.alt_phone AS "Alt Phone", ec.email AS "Email"
        FROM emergency_contacts ec JOIN employees e ON e.id = ec.employee_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id, ec.created_at
      ) r;

    WHEN 'employment' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 TO_CHAR(ee.effective_to,'MM/DD/YYYY') AS "Slice End", ee.is_active AS "Slice Is Active",
                 ee.designation AS "Designation", ee.job_title AS "Job Title", d.dept_id AS "Department Code",
                 mgr.employee_id AS "Manager Employee Code", TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
                 TO_CHAR(ee.end_date,'MM/DD/YYYY') AS "End Date", ee.work_country AS "Work Country (ISO3)",
                 ee.work_location AS "Work Location", c.code AS "Base Currency", ee.status::text AS "Status"
          FROM employee_employment ee JOIN employees e ON e.id = ee.employee_id
          LEFT JOIN departments d ON d.id = ee.dept_id LEFT JOIN employees mgr ON mgr.id = ee.manager_id
          LEFT JOIN currencies c ON c.id = ee.base_currency_id
          WHERE (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id, ee.effective_from
        ) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(ee.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 ee.designation AS "Designation", ee.job_title AS "Job Title", d.dept_id AS "Department Code",
                 mgr.employee_id AS "Manager Employee Code", TO_CHAR(ee.hire_date,'MM/DD/YYYY') AS "Hire Date",
                 TO_CHAR(ee.end_date,'MM/DD/YYYY') AS "End Date", ee.work_country AS "Work Country (ISO3)",
                 ee.work_location AS "Work Location", c.code AS "Base Currency", ee.status::text AS "Status"
          FROM employee_employment ee JOIN employees e ON e.id = ee.employee_id
          LEFT JOIN departments d ON d.id = ee.dept_id LEFT JOIN employees mgr ON mgr.id = ee.manager_id
          LEFT JOIN currencies c ON c.id = ee.base_currency_id
          WHERE ee.is_active = true AND (p_include_inactive OR e.status <> 'Inactive') ORDER BY e.employee_id
        ) r;
      END IF;

    WHEN 'job_relationships' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 TO_CHAR(s.effective_to,'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
                 i.relationship_code AS "Relationship Code *", mgr.employee_id AS "Value *"
          FROM employee_job_relationship_set s JOIN employee_job_relationship_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id JOIN employees mgr ON mgr.id = i.manager_employee_id
          WHERE (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, s.effective_from, i.relationship_code
        ) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 i.relationship_code AS "Relationship Code *", mgr.employee_id AS "Value *"
          FROM employee_job_relationship_set s JOIN employee_job_relationship_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id JOIN employees mgr ON mgr.id = i.manager_employee_id
          WHERE s.is_active = true AND (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, i.relationship_code
        ) r;
      END IF;

    WHEN 'dependents' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 TO_CHAR(s.effective_to,'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
                 i.dependent_code AS "Dependent Code *", i.dependent_name AS "Dependent Name *",
                 i.relationship_type AS "Relationship Code *", TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
                 CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
          FROM employee_dependent_set s JOIN employee_dependent_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id
          WHERE (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, s.effective_from, i.dependent_code
        ) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 i.dependent_code AS "Dependent Code *", i.dependent_name AS "Dependent Name *",
                 i.relationship_type AS "Relationship Code *", TO_CHAR(i.date_of_birth,'MM/DD/YYYY') AS "Date of Birth",
                 CASE WHEN i.insurance_eligible THEN 'Yes' ELSE 'No' END AS "Insurance Eligible"
          FROM employee_dependent_set s JOIN employee_dependent_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id
          WHERE s.is_active = true AND (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, i.dependent_code
        ) r;
      END IF;

    WHEN 'bank_accounts' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 TO_CHAR(s.effective_to,'MM/DD/YYYY') AS "Slice End", s.is_active AS "Slice Is Active",
                 i.bank_account_group_id::text AS "Account Group Id *", i.country_code AS "Country (ISO3) *",
                 i.currency_code AS "Currency Code *", i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name",
                 i.branch_code AS "Branch Code", i.account_holder_name AS "Account Holder Name *",
                 i.account_number AS "Account Number *", i.ifsc_code AS "IFSC Code", i.iban AS "IBAN",
                 i.swift_bic AS "SWIFT / BIC", CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary"
          FROM employee_bank_account_set s JOIN employee_bank_account_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id
          WHERE (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, s.effective_from, i.bank_name
        ) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT e.employee_id AS "Employee Code *", TO_CHAR(s.effective_from,'MM/DD/YYYY') AS "Effective Date *",
                 i.bank_account_group_id::text AS "Account Group Id *", i.country_code AS "Country (ISO3) *",
                 i.currency_code AS "Currency Code *", i.bank_name AS "Bank Name *", i.branch_name AS "Branch Name",
                 i.branch_code AS "Branch Code", i.account_holder_name AS "Account Holder Name *",
                 i.account_number AS "Account Number *", i.ifsc_code AS "IFSC Code", i.iban AS "IBAN",
                 i.swift_bic AS "SWIFT / BIC", CASE WHEN i.is_primary THEN 'Yes' ELSE 'No' END AS "Is Primary"
          FROM employee_bank_account_set s JOIN employee_bank_account_item i ON i.set_id = s.id
          JOIN employees e ON e.id = s.employee_id
          WHERE s.is_active = true AND (p_include_inactive OR e.status <> 'Inactive')
          ORDER BY e.employee_id, i.is_primary DESC, i.bank_name
        ) r;
      END IF;

    WHEN 'employees' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT e.employee_id AS "Employee Code *", e.name AS "Full Name *", e.business_email AS "Business Email",
               e.designation AS "Designation", e.job_title AS "Job Title", d.dept_id AS "Department Code",
               mgr.employee_id AS "Manager Employee Code", TO_CHAR(e.hire_date,'MM/DD/YYYY') AS "Hire Date",
               TO_CHAR(e.end_date,'MM/DD/YYYY') AS "End Date", e.status::text AS "Status"
        FROM employees e LEFT JOIN departments d ON d.id = e.dept_id LEFT JOIN employees mgr ON mgr.id = e.manager_id
        WHERE (p_include_inactive OR e.status <> 'Inactive') AND e.status NOT IN ('Draft','Incomplete')
        ORDER BY e.employee_id
      ) r;

    WHEN 'department' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT d.dept_id AS "Department Code *", d.name AS "Department Name *"
        FROM departments d WHERE d.deleted_at IS NULL ORDER BY d.dept_id
      ) r;

    WHEN 'picklist' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT pl.id::text AS "Picklist Id *", pv.ref_id AS "Ref Id *", pv.value AS "Value *",
               parent_pl.id::text AS "Parent Picklist Id", parent_pv.ref_id AS "Parent Ref Id",
               CASE WHEN pv.active THEN 'Yes' ELSE 'No' END AS "Active", pv.meta::text AS "Meta"
        FROM picklist_values pv JOIN picklists pl ON pl.id = pv.picklist_id
        LEFT JOIN picklist_values parent_pv ON parent_pv.id = pv.parent_value_id
        LEFT JOIN picklists parent_pl ON parent_pl.id = parent_pv.picklist_id
        WHERE (p_include_inactive OR pv.active = true) ORDER BY pl.id, pv.ref_id
      ) r;

    WHEN 'project' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT p.name AS "Project Name *", TO_CHAR(p.start_date,'MM/DD/YYYY') AS "Start Date",
               TO_CHAR(p.end_date,'MM/DD/YYYY') AS "End Date",
               CASE WHEN p.active THEN 'Yes' ELSE 'No' END AS "Active"
        FROM projects p WHERE (p_include_inactive OR p.active = true) ORDER BY p.name
      ) r;

    WHEN 'exchange_rate' THEN
      RETURN QUERY SELECT to_jsonb(r) FROM (
        SELECT fc.code AS "From Currency *", tc.code AS "To Currency *",
               TO_CHAR(er.effective_date,'MM/DD/YYYY') AS "Effective Date *", er.rate::text AS "Rate *"
        FROM exchange_rates er JOIN currencies fc ON fc.id = er.from_currency_id
        JOIN currencies tc ON tc.id = er.to_currency_id
        ORDER BY fc.code, tc.code, er.effective_date
      ) r;

    -- =========================================================================
    -- 16. education (field_of_study removed in mig 400)
    -- =========================================================================
    WHEN 'education' THEN
      IF p_mode = 'history' THEN
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                              AS "Employee Code *",
            ee.education_level                         AS "Education Level Code *",
            ee.degree                                  AS "Degree *",
            ee.institution                             AS "Institution *",
            TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
            TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
            ee.completion_status                        AS "Completion Status Code *",
            ee.grade_or_gpa                            AS "Grade / GPA",
            CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification",
            CASE WHEN ee.is_active THEN 'Yes' ELSE 'No' END                AS "Is Active"
          FROM   employee_education ee
          JOIN   employees e ON e.id = ee.employee_id
          WHERE  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id, ee.is_active DESC,
                    ee.is_highest_qualification DESC,
                    ee.end_date DESC NULLS FIRST, ee.start_date DESC
        ) r;
      ELSE
        RETURN QUERY SELECT to_jsonb(r) FROM (
          SELECT
            e.employee_id                              AS "Employee Code *",
            ee.education_level                         AS "Education Level Code *",
            ee.degree                                  AS "Degree *",
            ee.institution                             AS "Institution *",
            TO_CHAR(ee.start_date, 'MM/DD/YYYY')       AS "Start Date *",
            TO_CHAR(ee.end_date,   'MM/DD/YYYY')       AS "End Date",
            ee.completion_status                        AS "Completion Status Code *",
            ee.grade_or_gpa                            AS "Grade / GPA",
            CASE WHEN ee.is_highest_qualification THEN 'Yes' ELSE 'No' END AS "Highest Qualification"
          FROM   employee_education ee
          JOIN   employees e ON e.id = ee.employee_id
          WHERE  ee.is_active = true
            AND  (p_include_inactive OR e.status <> 'Inactive')
          ORDER  BY e.employee_id,
                    ee.is_highest_qualification DESC,
                    ee.end_date DESC NULLS FIRST, ee.start_date DESC
        ) r;
      END IF;

    ELSE
      RAISE EXCEPTION 'Unknown template_code: %. Check bulk_template_registry for valid codes.', p_template_code;

  END CASE;
END;
$$;

COMMENT ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) IS
  'Returns export rows as SETOF JSONB for all 16 bulk templates. '
  'Mig 400: education WHEN clause updated — field_of_study removed.';

REVOKE ALL     ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION bulk_export(TEXT, BOOLEAN, TEXT) TO authenticated;


-- Also update the registry schema_definition for education (remove Field of Study column)
UPDATE bulk_template_registry
SET schema_definition = jsonb_set(
  schema_definition,
  '{columns}',
  (
    SELECT jsonb_agg(col)
    FROM jsonb_array_elements(schema_definition->'columns') AS col
    WHERE col->>'name' <> 'Field of Study'
  )
)
WHERE template_code = 'education';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'employee_education'
ORDER BY ordinal_position;

-- =============================================================================
-- END OF MIGRATION 400
-- =============================================================================
