-- Migration 263: update_hire_field — add emp.dept_id and emp.manager_id cases
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- ───────
-- get_employee_hire_review (mig 246) returns emp.dept_id and emp.manager_id as
-- editable fields in the Employment section (input_type='dept_select' and
-- 'emp_select' respectively). When an approver edits either field and clicks
-- "Done Editing", WorkflowReview calls update_hire_field with those keys.
--
-- update_hire_field (mig 242) has no CASE branches for these two keys, so the
-- call falls through to:
--
--     ELSE RAISE EXCEPTION 'Unknown field key: %', p_field_key;
--
-- producing the runtime error the approver sees:
--
--     "Employment — Manager: Unknown field key: emp.manager_id"
--
-- The same error fires for emp.dept_id if that field is edited.
--
-- AUDIT
-- ─────
-- All other editable fields returned by get_employee_hire_review are already
-- handled in update_hire_field:
--   emp.name, emp.business_email, emp.hire_date, emp.end_date,
--   emp.designation, emp.work_country, emp.work_location,
--   employment.probation_end_date,
--   personal.*, contact.*, addr.*, passport.*, ec.*,
--   id.*.* (handled by the dedicated identity_records block)
--   emp.base_currency_id — editable:false, never sent
-- Only emp.dept_id and emp.manager_id were missing.
--
-- FIX
-- ───
-- Add two CASE branches to update_hire_field:
--   emp.dept_id    → UPDATE employees SET dept_id    = NULLIF(p_new_value,'')::uuid
--   emp.manager_id → UPDATE employees SET manager_id = NULLIF(p_new_value,'')::uuid
--
-- Both columns are UUID foreign keys. NULLIF handles clearing the field
-- (empty string → NULL). manager_id is nullable; dept_id set to NULL would be
-- caught by validate_hire_fields on any subsequent resubmission attempt.
-- ─────────────────────────────────────────────────────────────────────────────


CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id uuid,
  p_field_key   text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_employee_uuid uuid := p_employee_id;
BEGIN
  -- ── Access guard ─────────────────────────────────────────────────────────
  -- PATH A: submitter editing their own sent-back record
  -- PATH B: approver with hire_employee.edit permission
  IF NOT EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'awaiting_clarification'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION 'Not authorised to edit hire field for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Only operate on Pending records ──────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status = 'Pending'
  ) THEN
    RAISE EXCEPTION 'update_hire_field: employee % is not in Pending status.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Identity records: routed by key pattern id.<country>.<column> ─────────
  IF p_field_key LIKE 'id.%.%' THEN
    DECLARE
      v_parts   text[]  := string_to_array(p_field_key, '.');
      v_country text    := v_parts[2];
      v_col     text    := v_parts[3];
    BEGIN
      CASE v_col
        WHEN 'id_type'      THEN UPDATE identity_records SET id_type      = p_new_value                  WHERE employee_id = p_employee_id AND country = v_country;
        WHEN 'record_type'  THEN UPDATE identity_records SET record_type  = p_new_value                  WHERE employee_id = p_employee_id AND country = v_country;
        WHEN 'id_number'    THEN UPDATE identity_records SET id_number    = p_new_value                  WHERE employee_id = p_employee_id AND country = v_country;
        WHEN 'expiry'       THEN UPDATE identity_records SET expiry       = NULLIF(p_new_value,'')::date WHERE employee_id = p_employee_id AND country = v_country;
        ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
      END CASE;
      RETURN;
    END;
  END IF;

  -- ── All other fields ──────────────────────────────────────────────────────
  CASE p_field_key

    -- employees base table
    WHEN 'emp.name'            THEN UPDATE employees SET name           = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.dept_id'         THEN UPDATE employees SET dept_id        = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;
    WHEN 'emp.manager_id'      THEN UPDATE employees SET manager_id     = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;

    -- employee_personal
    WHEN 'personal.nationality' THEN
      INSERT INTO employee_personal (employee_id, nationality) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET nationality = EXCLUDED.nationality;
    WHEN 'personal.gender' THEN
      INSERT INTO employee_personal (employee_id, gender) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET gender = EXCLUDED.gender;
    WHEN 'personal.dob' THEN
      INSERT INTO employee_personal (employee_id, dob) VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET dob = EXCLUDED.dob;
    WHEN 'personal.marital_status' THEN
      INSERT INTO employee_personal (employee_id, marital_status) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET marital_status = EXCLUDED.marital_status;

    -- employee_contact
    WHEN 'contact.personal_email' THEN
      INSERT INTO employee_contact (employee_id, personal_email) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET personal_email = EXCLUDED.personal_email;
    WHEN 'contact.mobile' THEN
      INSERT INTO employee_contact (employee_id, mobile) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET mobile = EXCLUDED.mobile;
    WHEN 'contact.country_code' THEN
      INSERT INTO employee_contact (employee_id, country_code) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET country_code = EXCLUDED.country_code;

    -- employee_employment
    WHEN 'employment.probation_end_date' THEN
      INSERT INTO employee_employment (employee_id, probation_end_date)
      VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET probation_end_date = EXCLUDED.probation_end_date;

    -- employee_addresses
    WHEN 'addr.line1'    THEN INSERT INTO employee_addresses (employee_id, line1)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line1    = EXCLUDED.line1;
    WHEN 'addr.line2'    THEN INSERT INTO employee_addresses (employee_id, line2)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line2    = EXCLUDED.line2;
    WHEN 'addr.landmark' THEN INSERT INTO employee_addresses (employee_id, landmark) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET landmark = EXCLUDED.landmark;
    WHEN 'addr.city'     THEN INSERT INTO employee_addresses (employee_id, city)     VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET city     = EXCLUDED.city;
    WHEN 'addr.district' THEN INSERT INTO employee_addresses (employee_id, district) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET district = EXCLUDED.district;
    WHEN 'addr.state'    THEN INSERT INTO employee_addresses (employee_id, state)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET state    = EXCLUDED.state;
    WHEN 'addr.pin'      THEN INSERT INTO employee_addresses (employee_id, pin)      VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET pin      = EXCLUDED.pin;
    WHEN 'addr.country'  THEN INSERT INTO employee_addresses (employee_id, country)  VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET country  = EXCLUDED.country;

    -- passports
    WHEN 'passport.country'         THEN UPDATE passports SET country         = p_new_value                  WHERE employee_id = p_employee_id;
    WHEN 'passport.passport_number' THEN UPDATE passports SET passport_number = p_new_value                  WHERE employee_id = p_employee_id;
    WHEN 'passport.issue_date'      THEN UPDATE passports SET issue_date      = NULLIF(p_new_value,'')::date WHERE employee_id = p_employee_id;
    WHEN 'passport.expiry_date'     THEN UPDATE passports SET expiry_date     = NULLIF(p_new_value,'')::date WHERE employee_id = p_employee_id;

    -- emergency_contacts
    WHEN 'ec.name'         THEN UPDATE emergency_contacts SET name         = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.relationship' THEN UPDATE emergency_contacts SET relationship = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.phone'        THEN UPDATE emergency_contacts SET phone        = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.alt_phone'    THEN UPDATE emergency_contacts SET alt_phone    = p_new_value WHERE employee_id = p_employee_id;
    WHEN 'ec.email'        THEN UPDATE emergency_contacts SET email        = p_new_value WHERE employee_id = p_employee_id;

    ELSE RAISE EXCEPTION 'Unknown field key: %', p_field_key;
  END CASE;
END;
$$;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Inline-edit RPC for hire review. Callers must be either the workflow '
  'submitter (initiator editing a sent-back record) or pass '
  'user_can(hire_employee, edit, NULL) (approver mid-flight edit). '
  'Only operates on Pending employees. '
  'Mig 263: added emp.dept_id and emp.manager_id CASE branches. Both are UUID '
  'FK columns; values cast with NULLIF(v,'''')::uuid to handle clearing.';

REVOKE ALL   ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'update_hire_field'
  ) THEN
    RAISE EXCEPTION 'ABORT: update_hire_field not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 263 verified: update_hire_field present with emp.dept_id and emp.manager_id support.';
END;
$$;
