-- Migration 267: SECURITY DEFINER RPCs for hire review identity add / delete
-- ─────────────────────────────────────────────────────────────────────────────
--
-- WHY
-- ───
-- WorkflowReview.tsx was calling supabase.from('identity_records').insert()
-- and .delete() directly from the client.  Those calls go through Row Level
-- Security (RLS).  The RLS policy on identity_records grants write access via
-- user_can('identity_documents', 'edit', employee_id) — a permission approvers
-- do NOT hold; they only have hire_employee.edit.
--
-- Result: approver/initiator add-ID and delete-ID operations silently fail
-- (PostgREST returns no rows affected, no client error).
--
-- FIX
-- ───
-- Two SECURITY DEFINER functions that bypass RLS and apply the same access
-- guard already used by update_hire_field:
--   • submitter editing their own sent-back hire (awaiting_clarification), OR
--   • any user with hire_employee.edit permission (approver mid-flight).
--
-- 1. add_hire_identity_record(p_employee_id, p_country, p_id_type,
--                              p_record_type, p_id_number, p_expiry)
--    → INSERTs a new identity_records row; returns the new row id.
--
-- 2. delete_hire_identity_record(p_employee_id, p_record_id)
--    → DELETEs the specified row; employee_id guard prevents cross-employee
--      tampering.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. add_hire_identity_record ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION add_hire_identity_record(
  p_employee_id uuid,
  p_country     uuid,
  p_id_type     uuid,
  p_record_type text,
  p_id_number   text,
  p_expiry      date DEFAULT NULL
)
RETURNS uuid           -- returns the new identity_records.id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_id uuid;
BEGIN
  -- ── Access guard (same as update_hire_field) ─────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'awaiting_clarification'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION 'Not authorised to add identity record for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Editable-status guard ─────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status IN ('Pending', 'Incomplete')
  ) THEN
    RAISE EXCEPTION 'add_hire_identity_record: employee % is not in an editable status.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Insert ────────────────────────────────────────────────────────────────
  INSERT INTO identity_records (employee_id, country, id_type, record_type, id_number, expiry)
  VALUES (p_employee_id, p_country, p_id_type, p_record_type, p_id_number, p_expiry)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) IS
  'SECURITY DEFINER wrapper for inserting an identity_records row from the hire '
  'review screen.  Bypasses RLS (which gates on identity_documents.edit) and '
  'instead enforces the hire_employee.edit / submitter-ownership guard used by '
  'update_hire_field.  Returns the new row UUID.';

REVOKE ALL   ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION add_hire_identity_record(uuid, uuid, uuid, text, text, date) TO authenticated;


-- ── 2. delete_hire_identity_record ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION delete_hire_identity_record(
  p_employee_id uuid,
  p_record_id   uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'awaiting_clarification'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION 'Not authorised to delete identity record for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Editable-status guard ─────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status IN ('Pending', 'Incomplete')
  ) THEN
    RAISE EXCEPTION 'delete_hire_identity_record: employee % is not in an editable status.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Delete — employee_id guard prevents cross-employee tampering ──────────
  DELETE FROM identity_records
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;
END;
$$;

COMMENT ON FUNCTION delete_hire_identity_record(uuid, uuid) IS
  'SECURITY DEFINER wrapper for deleting an identity_records row from the hire '
  'review screen.  Bypasses RLS and enforces the hire_employee.edit / '
  'submitter-ownership guard.  The employee_id guard prevents cross-employee '
  'tampering.';

REVOKE ALL   ON FUNCTION delete_hire_identity_record(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION delete_hire_identity_record(uuid, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'add_hire_identity_record'
  ) THEN
    RAISE EXCEPTION 'ABORT: add_hire_identity_record not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'delete_hire_identity_record'
  ) THEN
    RAISE EXCEPTION 'ABORT: delete_hire_identity_record not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 267 verified: add_hire_identity_record and delete_hire_identity_record present.';
END;
$$;
