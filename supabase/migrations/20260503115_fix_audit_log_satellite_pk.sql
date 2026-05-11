-- =============================================================================
-- Migration 115: Fix trg_write_audit_log() for satellite tables
--
-- ROOT CAUSE
-- ──────────
-- trg_write_audit_log() read v_record_id from v_row->>'id'. Satellite tables
-- (employee_personal, employee_contact, employee_address, employee_passport,
-- employee_identity_documents, employee_emergency_contacts) have no 'id' column
-- — their PK is employee_id. So v_row->>'id' = NULL, violating the NOT NULL
-- constraint on employee_audit_log.record_id.
--
-- FIX
-- ───
-- COALESCE((v_row->>'id')::uuid, (v_row->>'employee_id')::uuid)
-- Tables with an 'id' column use it as before.
-- Satellite tables fall back to employee_id.
-- =============================================================================

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
  IF TG_OP = 'DELETE' THEN
    v_row := to_jsonb(OLD);
  ELSE
    v_row := to_jsonb(NEW);
  END IF;

  -- Satellite tables (employee_personal, employee_contact, etc.) use employee_id
  -- as their PK and have no 'id' column. Fall back gracefully.
  v_record_id := COALESCE((v_row->>'id')::uuid, (v_row->>'employee_id')::uuid);

  IF TG_TABLE_NAME = 'employees' THEN
    v_employee_id := v_record_id;
  ELSE
    v_employee_id := (v_row->>'employee_id')::uuid;
  END IF;

  INSERT INTO employee_audit_log (
    table_name, record_id, employee_id, operation, old_data, new_data, changed_by
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
  'Generic trigger function for employee_audit_log. '
  'record_id = id if present, else employee_id (for satellite tables). '
  'Attach to any employee-related table.';
