-- Migration 469: fix replace_identity_records permission check
--
-- Problem: the function only checked user_can('identity_document', 'edit', ...)
--   which fails during new hire saves because draft employees aren't covered
--   by the standard edit permission path. Super admins and the hire pipeline
--   (HR with hire_employee.edit + identity_document.edit) were both excluded.
--
-- Fix: add is_super_admin() and hire-pipeline guard, matching the pattern
--   used by submit_dependent_set, submit_bank_account_set, etc.

CREATE OR REPLACE FUNCTION replace_identity_records(
  p_employee_id uuid,
  p_records     jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec jsonb;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('identity_document', 'edit', p_employee_id)
    OR user_can('identity_document', 'edit', NULL)
    OR (
      -- Hire-pipeline: HR editing a draft/pending employee
      user_can('identity_document', 'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees
        WHERE id = p_employee_id
          AND status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'replace_identity_records: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Delete all existing records for this employee atomically with the insert.
  DELETE FROM identity_records WHERE employee_id = p_employee_id;

  -- Insert the new set (may be empty — that's a valid clear).
  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    INSERT INTO identity_records (
      employee_id, country, id_type, record_type, id_number, expiry
    ) VALUES (
      p_employee_id,
      NULLIF(v_rec->>'country',     ''),
      NULLIF(v_rec->>'id_type',     ''),
      NULLIF(v_rec->>'record_type', ''),
      NULLIF(v_rec->>'id_number',   ''),
      CASE WHEN v_rec->>'expiry' IS NOT NULL AND v_rec->>'expiry' != ''
           THEN (v_rec->>'expiry')::date ELSE NULL END
    );
  END LOOP;
END;
$$;

REVOKE ALL    ON FUNCTION replace_identity_records(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION replace_identity_records(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION replace_identity_records(uuid, jsonb) IS
  'Atomically replaces all identity_records rows for an employee. '
  'Covers super admins, direct edit permission, and the hire-pipeline path. '
  'DELETE + INSERT run in one implicit Postgres transaction. Mig 469.';
