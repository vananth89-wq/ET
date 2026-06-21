-- Migration 471: add hire-pipeline guard to upsert_passport, upsert_employee_address,
--               upsert_emergency_contact (text-param overloads used by upsert_hire_satellites)
--
-- Problem: all three text-param satellite functions only checked module.edit permission.
--   HR users with hire_employee.edit (but not passport/address/emergency_contacts.edit)
--   were denied when saving any of these sections in the new hire wizard.
--   upsert_hire_satellites already gates on hire_employee.edit at the top level,
--   so these inner checks were inconsistently stricter.
--
-- Fix: add the hire-pipeline path (hire_employee.edit + Draft/Incomplete/Pending employee)
--   to each function, matching the pattern in upsert_personal_info and replace_identity_records.

-- ── 1. upsert_passport ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_passport(
  p_employee_id uuid,
  p_country     text DEFAULT NULL,
  p_number      text DEFAULT NULL,
  p_issue_date  date DEFAULT NULL,
  p_expiry      date DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('passport', 'edit', p_employee_id)
    OR user_can('passport', 'edit', NULL)
    OR (
      user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees
        WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'upsert_passport: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_country IS NULL AND p_number IS NULL AND p_issue_date IS NULL AND p_expiry IS NULL THEN
    DELETE FROM passports WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO passports (employee_id, country, passport_number, issue_date, expiry_date)
  VALUES (p_employee_id, p_country, p_number, p_issue_date, p_expiry)
  ON CONFLICT (employee_id) DO UPDATE SET
    country         = EXCLUDED.country,
    passport_number = EXCLUDED.passport_number,
    issue_date      = EXCLUDED.issue_date,
    expiry_date     = EXCLUDED.expiry_date,
    updated_at      = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_passport(uuid, text, text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_passport(uuid, text, text, date, date) TO authenticated;

COMMENT ON FUNCTION upsert_passport(uuid, text, text, date, date) IS
  'Mig 471: added hire-pipeline guard (hire_employee.edit on Draft/Pending).';


-- ── 2. upsert_employee_address ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_employee_address(
  p_employee_id uuid,
  p_line1       text DEFAULT NULL,
  p_line2       text DEFAULT NULL,
  p_landmark    text DEFAULT NULL,
  p_city        text DEFAULT NULL,
  p_district    text DEFAULT NULL,
  p_state       text DEFAULT NULL,
  p_pin         text DEFAULT NULL,
  p_country     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('address', 'edit', p_employee_id)
    OR user_can('address', 'edit', NULL)
    OR (
      user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees
        WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'upsert_employee_address: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_line1 IS NULL AND p_city IS NULL THEN
    DELETE FROM employee_addresses WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO employee_addresses (
    employee_id, line1, line2, landmark, city, district, state, pin, country
  ) VALUES (
    p_employee_id, p_line1, p_line2, p_landmark, p_city, p_district, p_state, p_pin, p_country
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    line1      = EXCLUDED.line1,
    line2      = EXCLUDED.line2,
    landmark   = EXCLUDED.landmark,
    city       = EXCLUDED.city,
    district   = EXCLUDED.district,
    state      = EXCLUDED.state,
    pin        = EXCLUDED.pin,
    country    = EXCLUDED.country,
    updated_at = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) TO authenticated;

COMMENT ON FUNCTION upsert_employee_address(uuid,text,text,text,text,text,text,text,text) IS
  'Mig 471: added hire-pipeline guard (hire_employee.edit on Draft/Pending).';


-- ── 3. upsert_emergency_contact ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_emergency_contact(
  p_employee_id  uuid,
  p_name         text DEFAULT NULL,
  p_relationship text DEFAULT NULL,
  p_phone        text DEFAULT NULL,
  p_alt_phone    text DEFAULT NULL,
  p_email        text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('emergency_contacts', 'edit', p_employee_id)
    OR user_can('emergency_contacts', 'edit', NULL)
    OR (
      user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees
        WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RAISE EXCEPTION 'upsert_emergency_contact: permission denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_name IS NULL AND p_phone IS NULL THEN
    DELETE FROM emergency_contacts WHERE employee_id = p_employee_id;
    RETURN;
  END IF;

  INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
  VALUES (p_employee_id, COALESCE(p_name, ''), p_relationship, p_phone, p_alt_phone, p_email)
  ON CONFLICT (employee_id) DO UPDATE SET
    name         = EXCLUDED.name,
    relationship = EXCLUDED.relationship,
    phone        = EXCLUDED.phone,
    alt_phone    = EXCLUDED.alt_phone,
    email        = EXCLUDED.email,
    updated_at   = NOW();
END;
$$;

REVOKE ALL    ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) TO authenticated;

COMMENT ON FUNCTION upsert_emergency_contact(uuid,text,text,text,text,text) IS
  'Mig 471: added hire-pipeline guard (hire_employee.edit on Draft/Pending).';
