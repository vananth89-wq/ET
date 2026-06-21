-- =============================================================================
-- Migration 421 — bulk_diff_preview RPC
--
-- Called by the bulk-import-validator Edge Function after per-row validation.
-- Given an array of natural-key objects (snake_case keys, MM/DD/YYYY dates),
-- returns how many rows already exist in the DB (update) vs are new (insert).
--
-- This is informational — shown to the user before they click Process.
-- The processor performs the authoritative upsert regardless.
--
-- Signature:
--   bulk_diff_preview(p_template_code TEXT, p_keys JSONB)
--   RETURNS JSONB  →  {"new_count": N, "update_count": M}
--
-- p_keys is a JSON array of objects. Key names are headerToSnake(column_name):
--   "Employee Code *"      → "employee_code"
--   "Effective Date *"     → "effective_date"
--   "Department Code *"    → "department_code"
--   "Passport Number *"    → "passport_number"
--   "ID Type *"            → "id_type"
--   "ID Number *"          → "id_number"
--   "Education Level Code *" → "education_level_code"
--   "Start Date *"         → "start_date"
--   etc.
--
-- Date values are in MM/DD/YYYY format (same as import CSV).
-- For templates where the natural key involves UUIDs (picklist), values are UUID strings.
--
-- Predecessor: mig 420 (bulk_export Draft/Incomplete guard)
-- =============================================================================

CREATE OR REPLACE FUNCTION bulk_diff_preview(
  p_template_code TEXT,
  p_keys          JSONB   -- JSON array of natural-key objects
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new    BIGINT := 0;
  v_update BIGINT := 0;
BEGIN
  -- Permission check (same module as import)
  IF NOT user_can(p_template_code, 'bulk_import', NULL) THEN
    RAISE EXCEPTION 'Access denied: %.bulk_import required', p_template_code
      USING ERRCODE = '42501';
  END IF;

  CASE p_template_code

    -- =========================================================================
    -- 1. personal_info → employee_personal (employee_id + effective_from)
    -- =========================================================================
    WHEN 'personal_info' THEN
      SELECT
        COUNT(*) FILTER (WHERE ep.id IS NULL),
        COUNT(*) FILTER (WHERE ep.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN employee_personal ep
        ON ep.employee_id  = e.id
        AND ep.effective_from = TO_DATE(k->>'effective_date', 'MM/DD/YYYY');

    -- =========================================================================
    -- 2. contact_info → employee_contact (one row per employee)
    -- =========================================================================
    WHEN 'contact_info' THEN
      SELECT
        COUNT(*) FILTER (WHERE ec.employee_id IS NULL),
        COUNT(*) FILTER (WHERE ec.employee_id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN employee_contact ec ON ec.employee_id = e.id;

    -- =========================================================================
    -- 3. address → employee_addresses (one row per employee)
    -- =========================================================================
    WHEN 'address' THEN
      SELECT
        COUNT(*) FILTER (WHERE ea.employee_id IS NULL),
        COUNT(*) FILTER (WHERE ea.employee_id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN employee_addresses ea ON ea.employee_id = e.id;

    -- =========================================================================
    -- 4. passport → passports (employee_id + passport_number)
    -- =========================================================================
    WHEN 'passport' THEN
      SELECT
        COUNT(*) FILTER (WHERE p.id IS NULL),
        COUNT(*) FILTER (WHERE p.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN passports p
        ON p.employee_id    = e.id
        AND p.passport_number = k->>'passport_number';

    -- =========================================================================
    -- 5. identification → identity_records (employee_id + id_type + id_number)
    --    Note: id_type in CSV may be a label or ref_id; best-effort match.
    -- =========================================================================
    WHEN 'identification' THEN
      SELECT
        COUNT(*) FILTER (WHERE ir.id IS NULL),
        COUNT(*) FILTER (WHERE ir.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN identity_records ir
        ON ir.employee_id = e.id
        AND ir.id_number  = k->>'id_number';
        -- id_type match omitted intentionally: type is resolved label→ref_id in processor.
        -- Counting by employee + id_number is a good enough heuristic for the preview.

    -- =========================================================================
    -- 6. emergency_contact → emergency_contacts (one row per employee)
    -- =========================================================================
    WHEN 'emergency_contact' THEN
      SELECT
        COUNT(*) FILTER (WHERE ec.employee_id IS NULL),
        COUNT(*) FILTER (WHERE ec.employee_id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN emergency_contacts ec ON ec.employee_id = e.id;

    -- =========================================================================
    -- 7. employment → employee_employment (employee_id + effective_from)
    -- =========================================================================
    WHEN 'employment' THEN
      SELECT
        COUNT(*) FILTER (WHERE ee.id IS NULL),
        COUNT(*) FILTER (WHERE ee.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN employee_employment ee
        ON ee.employee_id  = e.id
        AND ee.effective_from = TO_DATE(k->>'effective_date', 'MM/DD/YYYY');

    -- =========================================================================
    -- 8. job_relationships → employee_job_relationship_set
    --    group_by_key: natural key is (employee + effective_date)
    -- =========================================================================
    WHEN 'job_relationships' THEN
      SELECT
        COUNT(*) FILTER (WHERE s.id IS NULL),
        COUNT(*) FILTER (WHERE s.id IS NOT NULL)
      INTO v_new, v_update
      FROM (
        SELECT DISTINCT k->>'employee_code' AS emp_code,
                        k->>'effective_date' AS eff_date
        FROM jsonb_array_elements(p_keys) AS k
      ) AS distinct_keys
      JOIN employees e ON e.employee_id = distinct_keys.emp_code
      LEFT JOIN employee_job_relationship_set s
        ON s.employee_id   = e.id
        AND s.effective_from = TO_DATE(distinct_keys.eff_date, 'MM/DD/YYYY')
        AND s.is_active    = true;

    -- =========================================================================
    -- 9. dependents → employee_dependent_set (group_by employee + effective_date)
    -- =========================================================================
    WHEN 'dependents' THEN
      SELECT
        COUNT(*) FILTER (WHERE s.id IS NULL),
        COUNT(*) FILTER (WHERE s.id IS NOT NULL)
      INTO v_new, v_update
      FROM (
        SELECT DISTINCT k->>'employee_code' AS emp_code,
                        k->>'effective_date' AS eff_date
        FROM jsonb_array_elements(p_keys) AS k
      ) AS distinct_keys
      JOIN employees e ON e.employee_id = distinct_keys.emp_code
      LEFT JOIN employee_dependent_set s
        ON s.employee_id   = e.id
        AND s.effective_from = TO_DATE(distinct_keys.eff_date, 'MM/DD/YYYY')
        AND s.is_active    = true;

    -- =========================================================================
    -- 10. bank_accounts → employee_bank_account_set (group_by employee + effective_date)
    -- =========================================================================
    WHEN 'bank_accounts' THEN
      SELECT
        COUNT(*) FILTER (WHERE s.id IS NULL),
        COUNT(*) FILTER (WHERE s.id IS NOT NULL)
      INTO v_new, v_update
      FROM (
        SELECT DISTINCT k->>'employee_code' AS emp_code,
                        k->>'effective_date' AS eff_date
        FROM jsonb_array_elements(p_keys) AS k
      ) AS distinct_keys
      JOIN employees e ON e.employee_id = distinct_keys.emp_code
      LEFT JOIN employee_bank_account_set s
        ON s.employee_id   = e.id
        AND s.effective_from = TO_DATE(distinct_keys.eff_date, 'MM/DD/YYYY')
        AND s.is_active    = true;

    -- =========================================================================
    -- 11. employees → employees table (employee_id)
    -- =========================================================================
    WHEN 'employees' THEN
      SELECT
        COUNT(*) FILTER (WHERE e.id IS NULL),
        COUNT(*) FILTER (WHERE e.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      LEFT JOIN employees e ON e.employee_id = k->>'employee_code';

    -- =========================================================================
    -- 12. department → departments (dept_id)
    -- =========================================================================
    WHEN 'department' THEN
      SELECT
        COUNT(*) FILTER (WHERE d.id IS NULL),
        COUNT(*) FILTER (WHERE d.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      LEFT JOIN departments d
        ON d.dept_id    = k->>'department_code'
        AND d.deleted_at IS NULL;

    -- =========================================================================
    -- 13. picklist → picklist_values (picklist_id UUID + ref_id)
    -- =========================================================================
    WHEN 'picklist' THEN
      SELECT
        COUNT(*) FILTER (WHERE pv.id IS NULL),
        COUNT(*) FILTER (WHERE pv.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      LEFT JOIN picklist_values pv
        ON pv.picklist_id = (k->>'picklist_id')::uuid
        AND pv.ref_id     = k->>'ref_id';

    -- =========================================================================
    -- 14. project → projects (name)
    -- =========================================================================
    WHEN 'project' THEN
      SELECT
        COUNT(*) FILTER (WHERE p.id IS NULL),
        COUNT(*) FILTER (WHERE p.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      LEFT JOIN projects p ON p.name = k->>'project_name';

    -- =========================================================================
    -- 15. exchange_rate → exchange_rates (from_currency + to_currency + effective_date)
    -- =========================================================================
    WHEN 'exchange_rate' THEN
      SELECT
        COUNT(*) FILTER (WHERE er.id IS NULL),
        COUNT(*) FILTER (WHERE er.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN currencies fc ON fc.code = k->>'from_currency'
      JOIN currencies tc ON tc.code = k->>'to_currency'
      LEFT JOIN exchange_rates er
        ON er.from_currency_id = fc.id
        AND er.to_currency_id  = tc.id
        AND er.effective_date  = TO_DATE(k->>'effective_date', 'MM/DD/YYYY');

    -- =========================================================================
    -- 16. education → employee_education (employee_id + education_level + institution + start_date)
    -- =========================================================================
    WHEN 'education' THEN
      SELECT
        COUNT(*) FILTER (WHERE ee.id IS NULL),
        COUNT(*) FILTER (WHERE ee.id IS NOT NULL)
      INTO v_new, v_update
      FROM jsonb_array_elements(p_keys) AS k
      JOIN employees e ON e.employee_id = k->>'employee_code'
      LEFT JOIN employee_education ee
        ON ee.employee_id    = e.id
        AND ee.education_level = k->>'education_level_code'
        AND ee.institution   = k->>'institution'
        AND ee.start_date    = TO_DATE(k->>'start_date', 'MM/DD/YYYY')
        AND ee.is_active     = true;

    ELSE
      -- Unknown template — return zeros rather than erroring (non-critical path)
      v_new    := 0;
      v_update := 0;

  END CASE;

  RETURN jsonb_build_object('new_count', v_new, 'update_count', v_update);

EXCEPTION WHEN OTHERS THEN
  -- Diff preview is non-critical; swallow errors and return zeros
  RETURN jsonb_build_object('new_count', 0, 'update_count', 0, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION bulk_diff_preview IS
  'Returns {new_count, update_count} for a set of natural-key objects from a bulk import CSV. '
  'Called by the validator Edge Function to show a diff preview before the user confirms processing. '
  'Non-authoritative — processor performs the actual upsert. '
  'Handles all 16 bulk templates.';

GRANT EXECUTE ON FUNCTION bulk_diff_preview(TEXT, JSONB) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 421
-- =============================================================================
