-- Migration 470: correct replace_identity_records hire-pipeline permission guard
--
-- Problem: mig 469 still required user_can('identity_document','edit',NULL) for
--   the hire-pipeline branch. HR users who only have hire_employee.edit (not
--   identity_document.edit) were still denied.
--
-- Fix: the hire-pipeline path requires ONLY hire_employee.edit, matching the
--   pattern used by submit_dependent_set, submit_bank_account_set, etc.

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
    -- Super admin bypass
    is_super_admin()

    -- Standard edit permission (existing active employee)
    OR user_can('identity_document', 'edit', p_employee_id)
    OR user_can('identity_document', 'edit', NULL)

    -- Hire-pipeline: only hire_employee.edit needed for Draft/Pending employees
    OR (
      user_can('hire_employee', 'edit', NULL)
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

  DELETE FROM identity_records WHERE employee_id = p_employee_id;

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
  'Atomically replaces identity_records for an employee. '
  'Guards: super admin | identity_document.edit | hire_employee.edit on Draft/Pending. '
  'Mig 470.';
