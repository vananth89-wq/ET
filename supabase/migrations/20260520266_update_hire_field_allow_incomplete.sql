-- Migration 266: update_hire_field — allow Incomplete status + upsert passport/emergency
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Three bugs fixed from migration 264:
--
-- BUG 1 — Status guard blocks initiator edits after send-back
--   When a hire is sent back for clarification, wf_sync_module_status sets
--   employees.status = 'Incomplete' (locked = false).  The initiator opens
--   WorkflowReview with role=initiator, clicks Update, edits fields, Done
--   Editing → every update_hire_field call fails:
--     "update_hire_field: employee <uuid> is not in Pending status."
--   FIX: accept status IN ('Pending', 'Incomplete').
--     Pending    = submitted, under review, locked=true  (approver mid-flight)
--     Incomplete = sent back OR rejected, locked=false   (initiator clarification)
--
-- BUG 2 — Passport fields silently disappear
--   passport.* used plain UPDATE … WHERE employee_id = <uuid>.
--   If the employee submitted without passport data, no row exists in passports,
--   so the UPDATE affects 0 rows — no error, no data saved.
--   FIX: use INSERT … ON CONFLICT (employee_id) DO UPDATE for all passport fields.
--
-- BUG 3 — Emergency contact fields silently disappear
--   Same root cause as BUG 2: plain UPDATE on emergency_contacts.
--   FIX: use INSERT … ON CONFLICT (employee_id) DO UPDATE for all ec.* fields.
--
-- All other logic is identical to migration 264.
-- ─────────────────────────────────────────────────────────────────────────────

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
BEGIN
  -- ── Access guard ─────────────────────────────────────────────────────────
  -- Allow: the workflow submitter editing their own sent-back record,
  --        OR any user with hire_employee.edit permission (approver).
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

  -- ── Editable-status guard ────────────────────────────────────────────────
  -- Pending    = submitted, under review (approver edits mid-flight)
  -- Incomplete = sent back for clarification or rejected (initiator edits)
  IF NOT EXISTS (
    SELECT 1 FROM employees
    WHERE  id     = p_employee_id
      AND  status IN ('Pending', 'Incomplete')
  ) THEN
    RAISE EXCEPTION 'update_hire_field: employee % is not in an editable status (Pending or Incomplete).',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Identity records: key pattern id.<rec_id_or_new>.<column> ────────────
  IF p_field_key LIKE 'id.%.%' THEN
    DECLARE
      v_parts    text[] := string_to_array(p_field_key, '.');
      v_rec_key  text   := v_parts[2];
      v_col      text   := v_parts[3];
      v_target   uuid;
    BEGIN
      IF v_rec_key = 'new' THEN
        v_target := (
          left(  md5(p_employee_id::text || ':identity_pending'), 8) || '-' ||
          substr(md5(p_employee_id::text || ':identity_pending'), 9,  4) || '-' ||
          substr(md5(p_employee_id::text || ':identity_pending'), 13, 4) || '-' ||
          substr(md5(p_employee_id::text || ':identity_pending'), 17, 4) || '-' ||
          substr(md5(p_employee_id::text || ':identity_pending'), 21, 12)
        )::uuid;
        INSERT INTO identity_records (id, employee_id)
        VALUES (v_target, p_employee_id)
        ON CONFLICT (id) DO NOTHING;
        CASE v_col
          WHEN 'country'     THEN UPDATE identity_records SET country     = p_new_value                  WHERE id = v_target;
          WHEN 'id_type'     THEN UPDATE identity_records SET id_type     = p_new_value                  WHERE id = v_target;
          WHEN 'record_type' THEN UPDATE identity_records SET record_type = p_new_value                  WHERE id = v_target;
          WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                  WHERE id = v_target;
          WHEN 'expiry'      THEN UPDATE identity_records SET expiry      = NULLIF(p_new_value,'')::date WHERE id = v_target;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;
      ELSE
        v_target := v_rec_key::uuid;
        CASE v_col
          WHEN 'country'     THEN UPDATE identity_records SET country     = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'id_type'     THEN UPDATE identity_records SET id_type     = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'record_type' THEN UPDATE identity_records SET record_type = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'id_number'   THEN UPDATE identity_records SET id_number   = p_new_value                  WHERE id = v_target AND employee_id = p_employee_id;
          WHEN 'expiry'      THEN UPDATE identity_records SET expiry      = NULLIF(p_new_value,'')::date WHERE id = v_target AND employee_id = p_employee_id;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;
      END IF;
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

    -- employee_addresses (already upserts in mig 264 — unchanged)
    WHEN 'addr.line1'    THEN INSERT INTO employee_addresses (employee_id, line1)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line1    = EXCLUDED.line1;
    WHEN 'addr.line2'    THEN INSERT INTO employee_addresses (employee_id, line2)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET line2    = EXCLUDED.line2;
    WHEN 'addr.landmark' THEN INSERT INTO employee_addresses (employee_id, landmark) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET landmark = EXCLUDED.landmark;
    WHEN 'addr.city'     THEN INSERT INTO employee_addresses (employee_id, city)     VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET city     = EXCLUDED.city;
    WHEN 'addr.district' THEN INSERT INTO employee_addresses (employee_id, district) VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET district = EXCLUDED.district;
    WHEN 'addr.state'    THEN INSERT INTO employee_addresses (employee_id, state)    VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET state    = EXCLUDED.state;
    WHEN 'addr.pin'      THEN INSERT INTO employee_addresses (employee_id, pin)      VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET pin      = EXCLUDED.pin;
    WHEN 'addr.country'  THEN INSERT INTO employee_addresses (employee_id, country)  VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET country  = EXCLUDED.country;

    -- passports — upsert so row is created when section was left blank on submission
    WHEN 'passport.country'         THEN
      INSERT INTO passports (employee_id, country)         VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET country         = EXCLUDED.country;
    WHEN 'passport.passport_number' THEN
      INSERT INTO passports (employee_id, passport_number) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET passport_number = EXCLUDED.passport_number;
    WHEN 'passport.issue_date'      THEN
      INSERT INTO passports (employee_id, issue_date)      VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET issue_date      = EXCLUDED.issue_date;
    WHEN 'passport.expiry_date'     THEN
      INSERT INTO passports (employee_id, expiry_date)     VALUES (p_employee_id, NULLIF(p_new_value,'')::date)
      ON CONFLICT (employee_id) DO UPDATE SET expiry_date     = EXCLUDED.expiry_date;

    -- emergency_contacts — upsert so row is created when section was left blank on submission
    WHEN 'ec.name'         THEN
      INSERT INTO emergency_contacts (employee_id, name)         VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET name         = EXCLUDED.name;
    WHEN 'ec.relationship' THEN
      INSERT INTO emergency_contacts (employee_id, relationship) VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET relationship = EXCLUDED.relationship;
    WHEN 'ec.phone'        THEN
      INSERT INTO emergency_contacts (employee_id, phone)        VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET phone        = EXCLUDED.phone;
    WHEN 'ec.alt_phone'    THEN
      INSERT INTO emergency_contacts (employee_id, alt_phone)    VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET alt_phone    = EXCLUDED.alt_phone;
    WHEN 'ec.email'        THEN
      INSERT INTO emergency_contacts (employee_id, email)        VALUES (p_employee_id, p_new_value)
      ON CONFLICT (employee_id) DO UPDATE SET email        = EXCLUDED.email;

    ELSE RAISE EXCEPTION 'Unknown field key: %', p_field_key;
  END CASE;
END;
$$;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Inline-edit RPC for hire review (approver and initiator). '
  'Mig 266 changes from mig 264: '
  '  (1) Status guard relaxed: Pending → Pending|Incomplete. '
  '      Incomplete = sent back for clarification or rejected (initiator edits). '
  '  (2) passport.* switched from plain UPDATE to INSERT ON CONFLICT upsert. '
  '      Prevents silent data loss when employee submitted without passport data. '
  '  (3) ec.* switched from plain UPDATE to INSERT ON CONFLICT upsert. '
  '      Same fix for emergency_contacts section. ';

REVOKE ALL   ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;
