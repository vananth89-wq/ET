-- =============================================================================
-- Migration 376 — Bulk Operations Framework: Processor RPC Wrappers
--
-- Creates the 12 processor RPCs that the bulk_import_processor Edge Function
-- calls per-row (or per-group) when running a bulk import. These wrap the
-- direct DB writes for modules that had no set-level or bulk-suitable RPC.
--
-- Already-existing RPCs (no wrappers needed here):
--   upsert_personal_info     — (p_employee_id, p_proposed_data, p_effective_from)
--   upsert_employment_info   — (p_employee_id, p_proposed_data, p_effective_from)
--   upsert_job_relationship_set — (p_employee_id, p_effective_from, p_items)
--
-- New RPCs created here (12):
--   Per-row, employee-scoped:
--     upsert_contact_info        (p_employee_id, p_row)
--     upsert_employee_address    (p_employee_id, p_row)
--     upsert_passport            (p_employee_id, p_row)
--     upsert_identity_record     (p_employee_id, p_row)
--     upsert_emergency_contact   (p_employee_id, p_row)
--   Per-row, admin master:
--     upsert_employee_master     (p_row)
--     upsert_department          (p_row)
--     upsert_picklist_value      (p_row)
--     upsert_project             (p_row)
--     upsert_exchange_rate       (p_row)
--   Group-by-key (set-snapshot):
--     upsert_dependent_set       (p_employee_id, p_effective_from, p_items)
--     upsert_bank_account_set    (p_employee_id, p_effective_from, p_items)
--
-- Calling convention (JSONB keys are snake_case DB column names):
--   Edge Function resolves CSV column names → snake_case before calling these.
--   All RPCs return  jsonb_build_object('ok', true/false, ...).
--   Workflow is bypassed for all (rule 13).
--   Audit batch id flows via current_setting('prowess.bulk_upload_job_id', true).
--
-- Design spec: docs/bulk-operations-framework.md §11, §14 Phase 12
-- Predecessor: mig 375 (registry seeds)
-- =============================================================================


-- =============================================================================
-- 0. Unique constraints needed by ON CONFLICT clauses in the RPCs below
-- =============================================================================

-- picklist_values: (picklist_id, ref_id) is logically unique — the UI enforces
-- this at the application layer but no DB constraint existed. Add it here.
CREATE UNIQUE INDEX IF NOT EXISTS uq_picklist_values_picklist_ref
  ON picklist_values (picklist_id, ref_id);

-- identity_records: (employee_id, id_type, id_number) is the natural key.
-- Dedup first (keep the most recently updated row per tuple).
DELETE FROM identity_records
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY employee_id, id_type, id_number
             ORDER BY updated_at DESC NULLS LAST, id DESC
           ) AS rn
    FROM identity_records
  ) ranked
  WHERE rn > 1
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_identity_records_emp_type_num
  ON identity_records (employee_id, id_type, id_number);

-- projects: name is the natural key (no code column exists).
-- NOTE: If duplicate project names already exist in prod, this index creation
-- will fail. In that case dedup first:
--   DELETE FROM projects a USING projects b
--   WHERE a.id > b.id AND a.name = b.name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_projects_name ON projects (name);


-- =============================================================================
-- 1. upsert_contact_info
-- Table: employee_contact (employee_id PK, country_code, mobile, personal_email)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_contact_info(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Permission: bulk_import on contact_info module
  IF NOT user_can('contact_info', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: contact_info.bulk_import required');
  END IF;

  INSERT INTO employee_contact (employee_id, country_code, mobile, personal_email)
  VALUES (
    p_employee_id,
    NULLIF(p_row->>'country_code', ''),
    NULLIF(p_row->>'mobile', ''),
    NULLIF(p_row->>'personal_email', '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    country_code   = COALESCE(NULLIF(EXCLUDED.country_code,   ''), employee_contact.country_code),
    mobile         = COALESCE(NULLIF(EXCLUDED.mobile,         ''), employee_contact.mobile),
    personal_email = COALESCE(NULLIF(EXCLUDED.personal_email, ''), employee_contact.personal_email),
    updated_at     = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_contact_info IS
  'Bulk-import processor for contact_info template. Upserts employee_contact. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_contact_info(UUID, JSONB) TO authenticated;


-- =============================================================================
-- 2. upsert_employee_address
-- Table: employee_addresses (employee_id UNIQUE, line1, line2, landmark,
--        city, district, state, pin, country)
-- =============================================================================

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

  INSERT INTO employee_addresses (
    employee_id, line1, line2, landmark, city, district, state, pin, country
  ) VALUES (
    p_employee_id,
    NULLIF(p_row->>'line1',    ''),
    NULLIF(p_row->>'line2',    ''),
    NULLIF(p_row->>'landmark', ''),
    NULLIF(p_row->>'city',     ''),
    NULLIF(p_row->>'district', ''),
    NULLIF(p_row->>'state',    ''),
    NULLIF(p_row->>'pin',      ''),
    NULLIF(p_row->>'country',  '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    line1      = COALESCE(NULLIF(EXCLUDED.line1,    ''), employee_addresses.line1),
    line2      = COALESCE(NULLIF(EXCLUDED.line2,    ''), employee_addresses.line2),
    landmark   = COALESCE(NULLIF(EXCLUDED.landmark, ''), employee_addresses.landmark),
    city       = COALESCE(NULLIF(EXCLUDED.city,     ''), employee_addresses.city),
    district   = COALESCE(NULLIF(EXCLUDED.district, ''), employee_addresses.district),
    state      = COALESCE(NULLIF(EXCLUDED.state,    ''), employee_addresses.state),
    pin        = COALESCE(NULLIF(EXCLUDED.pin,      ''), employee_addresses.pin),
    country    = COALESCE(NULLIF(EXCLUDED.country,  ''), employee_addresses.country),
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_employee_address IS
  'Bulk-import processor for address template. Upserts employee_addresses. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_employee_address(UUID, JSONB) TO authenticated;


-- =============================================================================
-- 3. upsert_passport
-- Table: passports (employee_id UNIQUE, passport_number, country,
--        issue_date, expiry_date)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_passport(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('passport', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: passport.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'passport_number', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'passport_number is required');
  END IF;

  INSERT INTO passports (
    employee_id, passport_number, country, issue_date, expiry_date
  ) VALUES (
    p_employee_id,
    p_row->>'passport_number',
    NULLIF(p_row->>'country',      ''),
    NULLIF(p_row->>'issue_date',   '')::date,
    NULLIF(p_row->>'expiry_date',  '')::date
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    passport_number = EXCLUDED.passport_number,
    country         = COALESCE(NULLIF(EXCLUDED.country,     ''), passports.country),
    issue_date      = COALESCE(EXCLUDED.issue_date,              passports.issue_date),
    expiry_date     = COALESCE(EXCLUDED.expiry_date,             passports.expiry_date),
    updated_at      = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_passport IS
  'Bulk-import processor for passport template. Upserts passports. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_passport(UUID, JSONB) TO authenticated;


-- =============================================================================
-- 4. upsert_identity_record
-- Table: identity_records (employee_id FK, id_type, id_number, country, expiry)
-- Natural key: (employee_id, id_type, id_number)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_identity_record(
  p_employee_id UUID,
  p_row         JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('identification', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: identification.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'id_type',   '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_type is required');
  END IF;
  IF NULLIF(p_row->>'id_number', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_number is required');
  END IF;

  INSERT INTO identity_records (
    employee_id, id_type, id_number, country, expiry
  ) VALUES (
    p_employee_id,
    p_row->>'id_type',
    p_row->>'id_number',
    NULLIF(p_row->>'country', ''),
    NULLIF(p_row->>'expiry',  '')::date
  )
  ON CONFLICT (employee_id, id_type, id_number) DO UPDATE SET
    country    = COALESCE(NULLIF(EXCLUDED.country, ''), identity_records.country),
    expiry     = COALESCE(EXCLUDED.expiry,              identity_records.expiry),
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_identity_record IS
  'Bulk-import processor for identification template. Upserts identity_records on (employee_id, id_type, id_number). Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_identity_record(UUID, JSONB) TO authenticated;


-- =============================================================================
-- 5. upsert_emergency_contact
-- Table: emergency_contacts (employee_id UNIQUE FK, name, relationship,
--        phone, alt_phone, email)
-- One record per employee.
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
BEGIN
  IF NOT user_can('emergency_contacts', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: emergency_contact.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  -- emergency_contacts has UNIQUE (employee_id) from mig 235
  -- (emergency_contacts_employee_id_key) — one record per employee.
  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (
    p_employee_id,
    p_row->>'name',
    NULLIF(p_row->>'relationship', ''),
    NULLIF(p_row->>'phone',        ''),
    NULLIF(p_row->>'alt_phone',    ''),
    NULLIF(p_row->>'email',        '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = COALESCE(NULLIF(EXCLUDED.relationship, ''), emergency_contacts.relationship),
    phone        = COALESCE(NULLIF(EXCLUDED.phone,        ''), emergency_contacts.phone),
    alt_phone    = COALESCE(NULLIF(EXCLUDED.alt_phone,    ''), emergency_contacts.alt_phone),
    email        = COALESCE(NULLIF(EXCLUDED.email,        ''), emergency_contacts.email),
    updated_at   = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_emergency_contact IS
  'Bulk-import processor for emergency_contact template. Upserts emergency_contacts. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_emergency_contact(UUID, JSONB) TO authenticated;


-- =============================================================================
-- 6. upsert_employee_master
-- Table: employees (employee_id TEXT UNIQUE, name, business_email,
--        designation, job_title, dept_id, manager_id, hire_date, end_date, status)
-- Natural key: employee_id (TEXT code)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_employee_master(
  p_row JSONB
)
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

  IF NULLIF(p_row->>'employee_id', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_id (employee code) is required');
  END IF;
  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  -- Resolve department code → UUID
  IF NULLIF(p_row->>'department_code', '') IS NOT NULL THEN
    SELECT id INTO v_dept_id FROM departments WHERE dept_id = p_row->>'department_code' AND deleted_at IS NULL;
    IF v_dept_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Department code not found: %s', p_row->>'department_code'));
    END IF;
  END IF;

  -- Resolve manager employee_id code → UUID
  IF NULLIF(p_row->>'manager_employee_code', '') IS NOT NULL THEN
    SELECT id INTO v_manager_id FROM employees WHERE employee_id = p_row->>'manager_employee_code';
    IF v_manager_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Manager employee code not found: %s', p_row->>'manager_employee_code'));
    END IF;
  END IF;

  -- Parse status enum (default Active for new employees)
  IF NULLIF(p_row->>'status', '') IS NOT NULL THEN
    BEGIN
      v_status := (p_row->>'status')::employee_status;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Invalid status value: %s', p_row->>'status'));
    END;
  ELSE
    v_status := 'Active';
  END IF;

  INSERT INTO employees (employee_id, name, business_email, designation, job_title,
                         dept_id, manager_id, hire_date, end_date, status)
  VALUES (
    p_row->>'employee_id',
    p_row->>'name',
    NULLIF(p_row->>'business_email', ''),
    NULLIF(p_row->>'designation',    ''),
    NULLIF(p_row->>'job_title',      ''),
    v_dept_id,
    v_manager_id,
    NULLIF(p_row->>'hire_date', '')::date,
    NULLIF(p_row->>'end_date',  '')::date,
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

COMMENT ON FUNCTION upsert_employee_master IS
  'Bulk-import processor for employees (master) template. Upserts the employees table on employee_id code. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_employee_master(JSONB) TO authenticated;


-- =============================================================================
-- 7. upsert_department
-- Table: departments (dept_id TEXT UNIQUE, name)
-- Natural key: dept_id (TEXT code)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_department(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT user_can('department', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: department.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'dept_id', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dept_id (department code) is required');
  END IF;
  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  INSERT INTO departments (dept_id, name)
  VALUES (p_row->>'dept_id', p_row->>'name')
  ON CONFLICT (dept_id) DO UPDATE SET
    name       = EXCLUDED.name,
    updated_at = NOW()
  WHERE departments.deleted_at IS NULL;  -- don't resurrect soft-deleted depts

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_department IS
  'Bulk-import processor for department template. Upserts departments on dept_id.';
GRANT EXECUTE ON FUNCTION upsert_department(JSONB) TO authenticated;


-- =============================================================================
-- 8. upsert_picklist_value
-- Table: picklist_values (picklist_id FK, ref_id, value, parent_value_id, active, meta)
-- Natural key: (picklist_id, ref_id)
-- p_row keys: picklist_id (TEXT — looked up in picklists), ref_id, value,
--             parent_picklist_id, parent_ref_id, active ('Yes'/'No'), meta (JSON string)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_picklist_value(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_picklist_id        UUID;
  v_parent_value_id    UUID;
  v_active             BOOLEAN;
  v_meta               JSONB;
BEGIN
  IF NOT user_can('picklist', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: picklist.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'picklist_id', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'picklist_id is required');
  END IF;
  IF NULLIF(p_row->>'ref_id', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ref_id is required');
  END IF;
  IF NULLIF(p_row->>'value', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'value is required');
  END IF;

  -- Resolve picklist_id: the column stores the UUID, but the CSV carries the
  -- string key (e.g. 'ID_COUNTRY'). We look up by picklists.id (UUID) first,
  -- then fall back to a name/code match.
  BEGIN
    v_picklist_id := (p_row->>'picklist_id')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    -- Not a UUID — treat as picklist name/code; not currently supported in schema
    -- (picklists has no 'code' column). Return a clear error.
    RETURN jsonb_build_object('ok', false, 'error',
      format('picklist_id must be a UUID. Received: %s', p_row->>'picklist_id'));
  END;

  IF NOT EXISTS (SELECT 1 FROM picklists WHERE id = v_picklist_id) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Picklist not found: %s', p_row->>'picklist_id'));
  END IF;

  -- Resolve optional cascading parent
  IF NULLIF(p_row->>'parent_picklist_id', '') IS NOT NULL
     AND NULLIF(p_row->>'parent_ref_id', '') IS NOT NULL THEN
    DECLARE
      v_parent_pl_id UUID;
    BEGIN
      v_parent_pl_id := (p_row->>'parent_picklist_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('parent_picklist_id must be a UUID. Received: %s', p_row->>'parent_picklist_id'));
    END;

    SELECT id INTO v_parent_value_id
    FROM   picklist_values
    WHERE  picklist_id = v_parent_pl_id
      AND  ref_id      = p_row->>'parent_ref_id';

    IF v_parent_value_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Parent value not found: picklist=%s ref_id=%s',
               p_row->>'parent_picklist_id', p_row->>'parent_ref_id'));
    END IF;
  END IF;

  -- Parse active flag (default true)
  v_active := CASE LOWER(NULLIF(p_row->>'active', ''))
                WHEN 'no'    THEN false
                WHEN 'false' THEN false
                ELSE true
              END;

  -- Parse meta JSON if provided
  IF NULLIF(p_row->>'meta', '') IS NOT NULL THEN
    BEGIN
      v_meta := (p_row->>'meta')::jsonb;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('meta is not valid JSON: %s', p_row->>'meta'));
    END;
  END IF;

  INSERT INTO picklist_values (picklist_id, ref_id, value, parent_value_id, active, meta)
  VALUES (v_picklist_id, p_row->>'ref_id', p_row->>'value', v_parent_value_id, v_active, v_meta)
  ON CONFLICT (picklist_id, ref_id) DO UPDATE SET
    value           = EXCLUDED.value,
    parent_value_id = COALESCE(EXCLUDED.parent_value_id, picklist_values.parent_value_id),
    active          = EXCLUDED.active,
    meta            = COALESCE(EXCLUDED.meta, picklist_values.meta),
    updated_at      = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_picklist_value IS
  'Bulk-import processor for picklist template. Upserts picklist_values on (picklist_id, ref_id). Supports cascading parent resolution.';
GRANT EXECUTE ON FUNCTION upsert_picklist_value(JSONB) TO authenticated;


-- =============================================================================
-- 9. upsert_project
-- Table: projects (id UUID PK, name TEXT NOT NULL UNIQUE, start_date, end_date, active)
-- Natural key: name (no code column — name is unique)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_project(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active BOOLEAN;
BEGIN
  IF NOT user_can('project', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: project.bulk_import required');
  END IF;

  IF NULLIF(p_row->>'name', '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name is required');
  END IF;

  v_active := CASE LOWER(NULLIF(p_row->>'active', ''))
                WHEN 'no'    THEN false
                WHEN 'false' THEN false
                ELSE true
              END;

  INSERT INTO projects (name, start_date, end_date, active)
  VALUES (
    p_row->>'name',
    NULLIF(p_row->>'start_date', '')::date,
    NULLIF(p_row->>'end_date',   '')::date,
    v_active
  )
  ON CONFLICT (name) DO UPDATE SET
    start_date = COALESCE(EXCLUDED.start_date, projects.start_date),
    end_date   = COALESCE(EXCLUDED.end_date,   projects.end_date),
    active     = EXCLUDED.active,
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_project IS
  'Bulk-import processor for project template. Upserts projects on name (natural key).';
GRANT EXECUTE ON FUNCTION upsert_project(JSONB) TO authenticated;


-- =============================================================================
-- 10. upsert_exchange_rate
-- Table: exchange_rates (from_currency_id, to_currency_id, effective_date, rate)
-- Natural key: (from_currency, to_currency, effective_date) — codes resolved to UUIDs
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_exchange_rate(
  p_row JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from_id UUID;
  v_to_id   UUID;
  v_rate    NUMERIC(18, 6);
  v_date    DATE;
BEGIN
  IF NOT user_can('exchange_rate', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: exchange_rate.bulk_import required');
  END IF;

  -- Resolve currency codes → UUIDs
  SELECT id INTO v_from_id FROM currencies WHERE code = p_row->>'from_currency' AND active = true;
  IF v_from_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('From currency not found: %s', p_row->>'from_currency'));
  END IF;

  SELECT id INTO v_to_id FROM currencies WHERE code = p_row->>'to_currency' AND active = true;
  IF v_to_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('To currency not found: %s', p_row->>'to_currency'));
  END IF;

  IF v_from_id = v_to_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'From and To currencies must differ');
  END IF;

  BEGIN
    v_rate := (p_row->>'rate')::NUMERIC(18, 6);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Invalid rate value: %s', p_row->>'rate'));
  END;

  IF v_rate <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Rate must be greater than 0');
  END IF;

  v_date := NULLIF(p_row->>'effective_date', '')::date;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_date is required');
  END IF;

  INSERT INTO exchange_rates (from_currency_id, to_currency_id, effective_date, rate)
  VALUES (v_from_id, v_to_id, v_date, v_rate)
  ON CONFLICT (from_currency_id, to_currency_id, effective_date) DO UPDATE SET
    rate       = EXCLUDED.rate,
    updated_at = NOW();

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_exchange_rate IS
  'Bulk-import processor for exchange_rate template. Upserts exchange_rates on (from_currency, to_currency, effective_date). Codes resolved to UUIDs.';
GRANT EXECUTE ON FUNCTION upsert_exchange_rate(JSONB) TO authenticated;


-- =============================================================================
-- 11. upsert_dependent_set
-- Delegates to fn_apply_dependent_set_transition (already exists, mig 342).
-- Signature matches upsert_job_relationship_set convention.
-- p_items: [{dependent_code, relationship_type, dependent_name, date_of_birth,
--            gender, insurance_eligible}]
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_dependent_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_set_id UUID;
BEGIN
  IF NOT user_can('dependents', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: dependents.bulk_import required');
  END IF;

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required');
  END IF;

  IF jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'p_items must be a JSONB array');
  END IF;

  -- Delegate to the existing set-transition function (advisory-locked, handles
  -- close-then-insert of the snapshot).
  v_set_id := fn_apply_dependent_set_transition(
    p_employee_id    => p_employee_id,
    p_effective_from => p_effective_from,
    p_items          => p_items,
    p_actor          => auth.uid()
  );

  RETURN jsonb_build_object('ok', true, 'set_id', v_set_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_dependent_set IS
  'Bulk-import processor for dependents template. Delegates to fn_apply_dependent_set_transition. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_dependent_set(UUID, DATE, JSONB) TO authenticated;


-- =============================================================================
-- 12. upsert_bank_account_set
-- Delegates to fn_apply_bank_account_set_transition (already exists, mig 329).
-- Signature matches upsert_job_relationship_set convention.
-- p_items: [{bank_account_group_id, country_code, currency_code, bank_name,
--            branch_name, branch_code, account_holder_name, account_number,
--            ifsc_code, iban, swift_bic, is_primary}]
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_set_id UUID;
BEGIN
  IF NOT user_can('bank_accounts', 'bulk_import', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: bank_accounts.bulk_import required');
  END IF;

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required');
  END IF;

  IF jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'p_items must be a JSONB array');
  END IF;

  -- Delegate to the existing set-transition function (advisory-locked, handles
  -- close-then-insert of the snapshot).
  v_set_id := fn_apply_bank_account_set_transition(
    p_employee_id    => p_employee_id,
    p_effective_from => p_effective_from,
    p_items          => p_items,
    p_actor          => auth.uid()
  );

  RETURN jsonb_build_object('ok', true, 'set_id', v_set_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_bank_account_set IS
  'Bulk-import processor for bank_accounts template. Delegates to fn_apply_bank_account_set_transition. Bypasses workflow.';
GRANT EXECUTE ON FUNCTION upsert_bank_account_set(UUID, DATE, JSONB) TO authenticated;


-- =============================================================================
-- Verification
-- =============================================================================

SELECT routine_name, routine_type
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name IN (
    'upsert_contact_info',
    'upsert_employee_address',
    'upsert_passport',
    'upsert_identity_record',
    'upsert_emergency_contact',
    'upsert_employee_master',
    'upsert_department',
    'upsert_picklist_value',
    'upsert_project',
    'upsert_exchange_rate',
    'upsert_dependent_set',
    'upsert_bank_account_set'
  )
ORDER BY routine_name;

-- Expected: 12 rows

-- =============================================================================
-- END OF MIGRATION 376
-- =============================================================================
