-- =============================================================================
-- Migration 241: update_hire_field — add caller ownership guard
--
-- Previously any authenticated user who knew a record_id could call this RPC
-- and mutate hire fields (SECURITY DEFINER bypasses RLS on satellite tables).
--
-- This migration adds a dual-path check before any write:
--
--   PATH A — Submitter:  caller is the submitted_by on the active
--             employee_hire workflow instance for this employee.
--             (Initiator editing a sent-back record)
--
--   PATH B — Approver:   caller holds the hire_employee.edit permission.
--             (Approver doing mid-flight inline edits)
--
-- If neither condition holds, the call is rejected with a 403-style EXCEPTION.
--
-- IMPORTANT: the existing status='Pending' guard is preserved as a second
-- layer — even authorised callers cannot mutate an Active employee.
-- =============================================================================

CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id uuid,
  p_field_key   text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parts     text[];
  v_record_id uuid;
  v_col       text;
BEGIN
  -- ── Guard 1: caller must be submitter OR hold hire_employee.edit ───────────
  IF NOT EXISTS (
    -- PATH A: caller submitted this hire workflow
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code   = 'employee_hire'
      AND  record_id     = p_employee_id
      AND  submitted_by  = auth.uid()
  ) AND NOT EXISTS (
    -- PATH B: caller holds hire_employee.edit permission
    SELECT 1
    FROM   user_roles        ur
    JOIN   role_permissions  rp ON rp.role_id    = ur.role_id
    JOIN   permissions        p ON p.id           = rp.permission_id
    WHERE  ur.user_id = auth.uid()
      AND  p.code     = 'hire_employee.edit'
  ) THEN
    RAISE EXCEPTION 'Not authorised to edit hire record for employee %.', p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Guard 2: only Pending employees may be edited inline ──────────────────
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status = 'Pending'
  ) THEN
    RAISE EXCEPTION 'Employee % is not in Pending status — inline edit blocked.', p_employee_id;
  END IF;

  -- ── identity_records: key format  id.<uuid>.<column> ─────────────────────
  IF p_field_key LIKE 'id.%.%' THEN
    v_parts     := string_to_array(p_field_key, '.');
    v_record_id := v_parts[2]::uuid;
    v_col       := v_parts[3];
    CASE v_col
      WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'expiry'      THEN UPDATE identity_records SET expiry       = NULLIF(p_new_value,'')::date  WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'country'     THEN UPDATE identity_records SET country      = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'id_type'     THEN UPDATE identity_records SET id_type      = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      WHEN 'record_type' THEN UPDATE identity_records SET record_type  = p_new_value                   WHERE id = v_record_id AND employee_id = p_employee_id;
      ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
    END CASE;
    RETURN;
  END IF;

  -- ── All other fields ──────────────────────────────────────────────────────
  CASE p_field_key

    -- employees
    WHEN 'emp.name'            THEN UPDATE employees SET name           = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.hire_date'       THEN UPDATE employees SET hire_date      = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;

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
    WHEN 'passport.country'         THEN UPDATE passports SET country         = p_new_value                   WHERE employee_id = p_employee_id;
    WHEN 'passport.passport_number' THEN UPDATE passports SET passport_number = p_new_value                   WHERE employee_id = p_employee_id;
    WHEN 'passport.issue_date'      THEN UPDATE passports SET issue_date      = NULLIF(p_new_value,'')::date  WHERE employee_id = p_employee_id;
    WHEN 'passport.expiry_date'     THEN UPDATE passports SET expiry_date     = NULLIF(p_new_value,'')::date  WHERE employee_id = p_employee_id;

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
  'submitter (initiator editing a sent-back record) or hold hire_employee.edit '
  'permission (approver mid-flight edit). Only operates on Pending employees.';

REVOKE ALL ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 241
-- =============================================================================
