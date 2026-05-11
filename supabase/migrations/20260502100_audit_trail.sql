-- =============================================================================
-- Migration 100: Audit trail — employee_audit_log
--
-- Creates an audit log table that records every INSERT, UPDATE, and DELETE on
-- the employees core table and all 7 satellite tables.  Backs the "History"
-- action in the Permission Matrix — when a role has *.history permission, they
-- can query the audit log for those records.
--
-- Tables audited:
--   employees            (core — all 3 lifecycle modules)
--   employee_personal
--   employee_contact
--   employee_employment
--   employee_addresses
--   emergency_contacts
--   identity_records
--   passports
--
-- RLS on employee_audit_log
-- ──────────────────────────
--   History access is module-specific:
--     employee_details.history   → audit rows for Active employees
--     inactive_employees.history → audit rows for Inactive employees
--     hire_employee.history      → audit rows for Draft/Incomplete employees
--     *.history                  → audit rows for that satellite module
--
--   Status routing on employees audit rows mirrors the core table RLS:
--     active row audit    → user_can('employee_details',   'history', employee_id)
--     inactive row audit  → user_can('inactive_employees', 'history', employee_id)
--     draft row audit     → user_can('hire_employee',      'history', employee_id)
--
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Audit log table
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS employee_audit_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name   text        NOT NULL,
  record_id    uuid        NOT NULL,         -- the PK of the changed row
  employee_id  uuid        REFERENCES employees(id) ON DELETE SET NULL,
  operation    text        NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
  old_data     jsonb,                        -- NULL on INSERT
  new_data     jsonb,                        -- NULL on DELETE
  changed_by   uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_employee_id   ON employee_audit_log (employee_id);
CREATE INDEX IF NOT EXISTS idx_audit_table_record  ON employee_audit_log (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_changed_at    ON employee_audit_log (changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_changed_by    ON employee_audit_log (changed_by);

ALTER TABLE employee_audit_log ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE employee_audit_log IS
  'Audit trail for all employee data changes. One row per INSERT/UPDATE/DELETE '
  'on employees and its 7 satellite tables. RLS gates access via *.history permissions.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Generic audit trigger function
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_write_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_record_id   uuid;
  v_employee_id uuid;
  v_row         jsonb;
BEGIN
  -- Determine which row changed and extract its employee_id
  IF TG_OP = 'DELETE' THEN
    v_row := to_jsonb(OLD);
  ELSE
    v_row := to_jsonb(NEW);
  END IF;

  -- record_id = the PK column 'id'
  v_record_id := (v_row->>'id')::uuid;

  -- employee_id: for the employees table itself it IS the record_id;
  -- for satellite tables it is the employee_id FK column.
  IF TG_TABLE_NAME = 'employees' THEN
    v_employee_id := v_record_id;
  ELSE
    v_employee_id := (v_row->>'employee_id')::uuid;
  END IF;

  INSERT INTO employee_audit_log (
    table_name,
    record_id,
    employee_id,
    operation,
    old_data,
    new_data,
    changed_by
  ) VALUES (
    TG_TABLE_NAME,
    v_record_id,
    v_employee_id,
    TG_OP,
    CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
    auth.uid()
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION trg_write_audit_log() IS
  'Generic trigger function that writes one row to employee_audit_log for every '
  'INSERT, UPDATE, or DELETE. Attach to any employee-related table.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Attach trigger to each table
-- ─────────────────────────────────────────────────────────────────────────────

-- employees (core)
DROP TRIGGER IF EXISTS audit_employees ON employees;
CREATE TRIGGER audit_employees
  AFTER INSERT OR UPDATE OR DELETE ON employees
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- employee_personal
DROP TRIGGER IF EXISTS audit_employee_personal ON employee_personal;
CREATE TRIGGER audit_employee_personal
  AFTER INSERT OR UPDATE OR DELETE ON employee_personal
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- employee_contact
DROP TRIGGER IF EXISTS audit_employee_contact ON employee_contact;
CREATE TRIGGER audit_employee_contact
  AFTER INSERT OR UPDATE OR DELETE ON employee_contact
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- employee_employment
DROP TRIGGER IF EXISTS audit_employee_employment ON employee_employment;
CREATE TRIGGER audit_employee_employment
  AFTER INSERT OR UPDATE OR DELETE ON employee_employment
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- employee_addresses
DROP TRIGGER IF EXISTS audit_employee_addresses ON employee_addresses;
CREATE TRIGGER audit_employee_addresses
  AFTER INSERT OR UPDATE OR DELETE ON employee_addresses
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- emergency_contacts
DROP TRIGGER IF EXISTS audit_emergency_contacts ON emergency_contacts;
CREATE TRIGGER audit_emergency_contacts
  AFTER INSERT OR UPDATE OR DELETE ON emergency_contacts
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- identity_records
DROP TRIGGER IF EXISTS audit_identity_records ON identity_records;
CREATE TRIGGER audit_identity_records
  AFTER INSERT OR UPDATE OR DELETE ON identity_records
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();

-- passports
DROP TRIGGER IF EXISTS audit_passports ON passports;
CREATE TRIGGER audit_passports
  AFTER INSERT OR UPDATE OR DELETE ON passports
  FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RLS policies on employee_audit_log
-- ─────────────────────────────────────────────────────────────────────────────

-- SELECT: module-specific history permission, status-routed for employees table
CREATE POLICY audit_select ON employee_audit_log FOR SELECT
  USING (
    -- Employees core table — route by the employee's current status
    (
      table_name = 'employees'
      AND employee_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM employees e WHERE e.id = employee_audit_log.employee_id AND e.deleted_at IS NULL
        AND (
          (e.status = 'Active'                    AND user_can('employee_details',   'history', e.id))
          OR (e.status = 'Inactive'               AND user_can('inactive_employees', 'history', e.id))
          OR (e.status IN ('Draft', 'Incomplete') AND user_can('hire_employee',      'history', e.id))
        )
      )
    )
    -- Satellite tables — map table_name to module code
    OR (table_name = 'employee_personal'   AND employee_id IS NOT NULL AND user_can('personal_info',       'history', employee_id))
    OR (table_name = 'employee_contact'    AND employee_id IS NOT NULL AND user_can('contact_info',        'history', employee_id))
    OR (table_name = 'employee_employment' AND employee_id IS NOT NULL AND user_can('employment',          'history', employee_id))
    OR (table_name = 'employee_addresses'  AND employee_id IS NOT NULL AND user_can('address',             'history', employee_id))
    OR (table_name = 'emergency_contacts'  AND employee_id IS NOT NULL AND user_can('emergency_contacts',  'history', employee_id))
    OR (table_name = 'identity_records'    AND employee_id IS NOT NULL AND user_can('identity_documents',  'history', employee_id))
    OR (table_name = 'passports'           AND employee_id IS NOT NULL AND user_can('passport',            'history', employee_id))
  );

-- INSERT: only the trigger function (SECURITY DEFINER) writes to this table
-- Deny direct inserts from authenticated users
CREATE POLICY audit_insert ON employee_audit_log FOR INSERT
  WITH CHECK (false);

-- No UPDATE or DELETE on audit log — immutable by design
CREATE POLICY audit_update ON employee_audit_log FOR UPDATE
  USING (false);

CREATE POLICY audit_delete ON employee_audit_log FOR DELETE
  USING (false);


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
  trigger_name,
  event_object_table AS "table",
  action_timing      AS timing
FROM information_schema.triggers
WHERE trigger_name LIKE 'audit_%'
ORDER BY event_object_table;

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'employee_audit_log'
ORDER BY cmd;

-- =============================================================================
-- END OF MIGRATION 100
-- =============================================================================
