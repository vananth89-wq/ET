-- =============================================================================
-- Migration 449 — Fix all remaining p_row JSONB key mismatches
--
-- Root cause: headerToSnake() in the bulk processor converts CSV column headers
-- to snake_case keys. The RPCs were written with different key names.
--
-- All mismatches found via audit:
--
-- TEMPLATE     COLUMN              headerToSnake()     RPC was reading   STATUS
-- ──────────────────────────────────────────────────────────────────────────────
-- address      "Line 1"            line_1              line1             ✗ WRONG
-- address      "Line 2"            line_2              line2             ✗ WRONG
-- address      "Postal Code"       postal_code         pin               ✗ WRONG
-- address      "Country (ISO3)"    country_iso3        country           ✗ WRONG
-- employees    "Employee Code *"   employee_code       employee_id       ✗ WRONG
-- employees    "Full Name *"       full_name           name              ✗ WRONG
-- employees    "Work Country(ISO3)"work_country_iso3   work_country      ✗ WRONG
--
-- Already fixed in prior migrations:
-- emergency_contact "Contact Name *" → contact_name   (mig 447)
-- passport     "Country (ISO3)"    → country_iso3     (mig 445)
-- identification "Country (ISO3)"  → country_iso3     (mig 446)
--
-- Confirmed OK (no mismatches):
-- contact_info, bank_accounts, dependents, job_relationships, identification ✓
-- employment: uses custom processor path (getCellValue, not p_row) ✓
-- =============================================================================

-- ── 1. upsert_employee_address — fix line_1/line_2/postal_code/country_iso3 ──

CREATE OR REPLACE FUNCTION upsert_employee_address(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('address', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: address.bulk_import required');
  END IF;

  -- headerToSnake mappings:
  --   "Line 1"         → line_1
  --   "Line 2"         → line_2
  --   "Postal Code"    → postal_code  (DB column is still named "pin")
  --   "Country (ISO3)" → country_iso3 (stored as UUID via resolve_picklist_id if needed,
  --                                    but address.country is free-text ISO3 code)
  INSERT INTO employee_addresses (
    employee_id, line1, line2, landmark, city, district, state, pin, country
  ) VALUES (
    p_employee_id,
    NULLIF(trim(p_row->>'line_1'),       ''),
    NULLIF(trim(p_row->>'line_2'),       ''),
    NULLIF(trim(p_row->>'landmark'),     ''),
    NULLIF(trim(p_row->>'city'),         ''),
    NULLIF(trim(p_row->>'district'),     ''),
    NULLIF(trim(p_row->>'state'),        ''),
    NULLIF(trim(p_row->>'postal_code'),  ''),
    NULLIF(trim(p_row->>'country_iso3'), '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    line1    = COALESCE(NULLIF(EXCLUDED.line1,    ''), employee_addresses.line1),
    line2    = COALESCE(NULLIF(EXCLUDED.line2,    ''), employee_addresses.line2),
    landmark = COALESCE(NULLIF(EXCLUDED.landmark, ''), employee_addresses.landmark),
    city     = COALESCE(NULLIF(EXCLUDED.city,     ''), employee_addresses.city),
    district = COALESCE(NULLIF(EXCLUDED.district, ''), employee_addresses.district),
    state    = COALESCE(NULLIF(EXCLUDED.state,    ''), employee_addresses.state),
    pin      = COALESCE(NULLIF(EXCLUDED.pin,      ''), employee_addresses.pin),
    country  = COALESCE(NULLIF(EXCLUDED.country,  ''), employee_addresses.country),
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_employee_address(UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION upsert_employee_address(uuid, jsonb) IS
  'Mig 449: fixed JSONB keys — line_1/line_2 (was line1/line2), '
  'postal_code (was pin), country_iso3 (was country).';

-- ── 2. upsert_employee_master — fix employee_code/full_name/work_country_iso3 ─
-- Note: work_country is NOT in the employees table directly (it is in
-- employee_employment). The employees master template schema has it listed
-- but the INSERT does not include it. Keeping that behaviour — just fixing
-- the mandatory-key reads that caused every row to fail.

CREATE OR REPLACE FUNCTION upsert_employee_master(p_row JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dept_id    UUID;
  v_manager_id UUID;
  v_status     employee_status;
BEGIN
  IF NOT user_can('employees', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: employees.bulk_import required');
  END IF;

  -- headerToSnake("Employee Code *") → employee_code
  IF NULLIF(trim(p_row->>'employee_code'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Employee Code is required');
  END IF;
  -- headerToSnake("Full Name *") → full_name
  IF NULLIF(trim(p_row->>'full_name'), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Full Name is required');
  END IF;

  -- Resolve department code → UUID
  IF NULLIF(trim(p_row->>'department_code'), '') IS NOT NULL THEN
    SELECT id INTO v_dept_id FROM departments
    WHERE dept_id = trim(p_row->>'department_code') AND deleted_at IS NULL;
    IF v_dept_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Department code not found: %s', trim(p_row->>'department_code')));
    END IF;
  END IF;

  -- Resolve manager employee code → UUID
  IF NULLIF(trim(p_row->>'manager_employee_code'), '') IS NOT NULL THEN
    SELECT id INTO v_manager_id FROM employees
    WHERE employee_id = trim(p_row->>'manager_employee_code');
    IF v_manager_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Manager employee code not found: %s', trim(p_row->>'manager_employee_code')));
    END IF;
  END IF;

  -- Parse status enum
  IF NULLIF(trim(p_row->>'status'), '') IS NOT NULL THEN
    BEGIN
      v_status := (trim(p_row->>'status'))::employee_status;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Invalid status value: %s', trim(p_row->>'status')));
    END;
  ELSE
    v_status := 'Active';
  END IF;

  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  INSERT INTO employees (employee_id, name, business_email, designation, job_title,
                         dept_id, manager_id, hire_date, end_date, status)
  VALUES (
    trim(p_row->>'employee_code'),
    trim(p_row->>'full_name'),
    NULLIF(trim(p_row->>'business_email'), ''),
    NULLIF(trim(p_row->>'designation'),    ''),
    NULLIF(trim(p_row->>'job_title'),      ''),
    v_dept_id,
    v_manager_id,
    NULLIF(trim(p_row->>'hire_date'), '')::date,
    NULLIF(trim(p_row->>'end_date'),  '')::date,
    v_status
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name           = EXCLUDED.name,
    business_email = COALESCE(NULLIF(EXCLUDED.business_email, ''), employees.business_email),
    designation    = COALESCE(NULLIF(EXCLUDED.designation,    ''), employees.designation),
    job_title      = COALESCE(NULLIF(EXCLUDED.job_title,      ''), employees.job_title),
    dept_id        = COALESCE(EXCLUDED.dept_id,    employees.dept_id),
    manager_id     = COALESCE(EXCLUDED.manager_id, employees.manager_id),
    hire_date      = COALESCE(EXCLUDED.hire_date,  employees.hire_date),
    end_date       = COALESCE(EXCLUDED.end_date,   employees.end_date),
    status         = EXCLUDED.status,
    updated_at     = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_employee_master(JSONB) TO authenticated;

COMMENT ON FUNCTION upsert_employee_master(jsonb) IS
  'Mig 449: fixed JSONB keys — employee_code (was employee_id), '
  'full_name (was name). Mig 432 allow_name_sync bypass preserved.';

-- =============================================================================
-- END OF MIGRATION 449
-- =============================================================================
