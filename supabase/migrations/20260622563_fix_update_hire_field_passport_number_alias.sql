-- Migration 563 — Fix update_hire_field: passport.number alias + ec NOT NULL guard
-- ────────────────────────────────────────────────────────────────────────────────
-- Fix 1 (passport.number alias):
--   get_employee_hire_review (mig 406+) returns the passport number field with
--   key 'passport.number', but update_hire_field (mig 347) only handled
--   'passport.passport_number'. This caused "Unknown field key: passport.number".
--   Fix: accept both keys in one WHEN clause.
--
-- Fix 2 (emergency_contacts NOT NULL guard):
--   emergency_contacts.name is NOT NULL. Saving any ec.* field other than
--   ec.name (e.g. ec.alt_phone) on an employee with no existing row fails with
--   "null value in column 'name' violates not-null constraint" because the INSERT
--   omitted name. Fix: all non-name ec INSERTs supply name='' as a safe default;
--   ON CONFLICT DO UPDATE only touches the specific column so existing names are
--   never overwritten.
--
-- No frontend changes required.

CREATE OR REPLACE FUNCTION update_hire_field(
  p_employee_id  uuid,
  p_field_key    text,
  p_new_value    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parts      text[];
  v_prefix     text;
  v_target     uuid;
  v_pi_result  jsonb;
  v_today      date := CURRENT_DATE;
  v_new_date   date;
BEGIN

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('hire_employee', 'edit', NULL)
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied: you do not have permission to edit this hire record.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_parts  := string_to_array(p_field_key, '.');
  v_prefix := v_parts[1];

  -- ── Identity records (id.<uuid_or_new>.<col>) ─────────────────────────────
  IF v_prefix = 'id' THEN
    DECLARE
      v_id_key text := v_parts[2];
      v_col    text := v_parts[3];
    BEGIN
      IF v_id_key = 'new' THEN
        v_target := (md5(p_employee_id::text || ':identity_pending'))::uuid;
        CASE v_col
          WHEN 'country'      THEN INSERT INTO identity_records (id, employee_id, country)      VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET country      = EXCLUDED.country;
          WHEN 'id_type'      THEN INSERT INTO identity_records (id, employee_id, id_type)      VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET id_type      = EXCLUDED.id_type;
          WHEN 'record_type'  THEN INSERT INTO identity_records (id, employee_id, record_type)  VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET record_type  = EXCLUDED.record_type;
          WHEN 'id_number'    THEN INSERT INTO identity_records (id, employee_id, id_number)    VALUES (v_target, p_employee_id, p_new_value) ON CONFLICT (id) DO UPDATE SET id_number    = EXCLUDED.id_number;
          WHEN 'expiry'       THEN INSERT INTO identity_records (id, employee_id, expiry)       VALUES (v_target, p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (id) DO UPDATE SET expiry = EXCLUDED.expiry;
          ELSE RAISE EXCEPTION 'Unknown identity_records column: %', v_col;
        END CASE;
      ELSE
        v_target := v_id_key::uuid;
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

    -- ── emp.hire_date — update employees + re-anchor employee_personal ──────
    WHEN 'emp.hire_date' THEN
      v_new_date := NULLIF(p_new_value, '')::date;
      UPDATE employees SET hire_date = v_new_date WHERE id = p_employee_id;

      IF v_new_date IS NOT NULL AND EXISTS (
        SELECT 1 FROM employee_personal
        WHERE  employee_id  = p_employee_id
          AND  effective_to = '9999-12-31'::date
          AND  is_active    = true
      ) THEN
        v_pi_result := upsert_personal_info(
          p_employee_id,
          '{}'::jsonb,
          v_new_date
        );
        IF NOT (v_pi_result->>'ok')::boolean THEN
          RAISE WARNING 'update_hire_field: employee_personal re-anchor failed for employee %: %',
            p_employee_id, v_pi_result->>'error';
        END IF;
      END IF;

    -- employees base table
    WHEN 'emp.business_email'  THEN UPDATE employees SET business_email = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.end_date'        THEN UPDATE employees SET end_date       = NULLIF(p_new_value,'')::date WHERE id = p_employee_id;
    WHEN 'emp.designation'     THEN UPDATE employees SET designation    = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_country'    THEN UPDATE employees SET work_country   = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.work_location'   THEN UPDATE employees SET work_location  = p_new_value                  WHERE id = p_employee_id;
    WHEN 'emp.dept_id'         THEN UPDATE employees SET dept_id        = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;
    WHEN 'emp.manager_id'      THEN UPDATE employees SET manager_id     = NULLIF(p_new_value,'')::uuid WHERE id = p_employee_id;

    -- employee_personal — route through upsert_personal_info
    WHEN 'personal.first_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('first_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.first_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.middle_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('middle_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.middle_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.last_name' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('last_name', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.last_name update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.nationality' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('nationality', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.nationality update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.gender' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('gender', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.gender update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.dob' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('dob', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.dob update failed: %', v_pi_result->>'error';
      END IF;

    WHEN 'personal.marital_status' THEN
      v_pi_result := upsert_personal_info(
        p_employee_id,
        jsonb_build_object('marital_status', NULLIF(p_new_value, '')),
        COALESCE((SELECT hire_date FROM employees WHERE id = p_employee_id), v_today)
      );
      IF NOT (v_pi_result->>'ok')::boolean THEN
        RAISE EXCEPTION 'personal.marital_status update failed: %', v_pi_result->>'error';
      END IF;

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
    -- 'passport.number' is an alias for 'passport.passport_number' —
    -- get_employee_hire_review (mig 406+) emits 'passport.number' as the key.
    WHEN 'passport.country'         THEN INSERT INTO passports (employee_id, country)         VALUES (p_employee_id, p_new_value)                  ON CONFLICT (employee_id) DO UPDATE SET country         = EXCLUDED.country;
    WHEN 'passport.passport_number',
         'passport.number'          THEN INSERT INTO passports (employee_id, passport_number) VALUES (p_employee_id, p_new_value)                  ON CONFLICT (employee_id) DO UPDATE SET passport_number = EXCLUDED.passport_number;
    WHEN 'passport.issue_date'      THEN INSERT INTO passports (employee_id, issue_date)      VALUES (p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (employee_id) DO UPDATE SET issue_date      = EXCLUDED.issue_date;
    WHEN 'passport.expiry_date'     THEN INSERT INTO passports (employee_id, expiry_date)     VALUES (p_employee_id, NULLIF(p_new_value,'')::date) ON CONFLICT (employee_id) DO UPDATE SET expiry_date     = EXCLUDED.expiry_date;

    -- emergency_contacts
    -- name is NOT NULL — always present in its own WHEN so the INSERT is safe.
    -- All other ec fields supply name='' on INSERT so a fresh row doesn't violate
    -- the NOT NULL constraint; ON CONFLICT DO UPDATE only sets the target column.
    WHEN 'ec.name'         THEN INSERT INTO emergency_contacts (employee_id, name)                   VALUES (p_employee_id, p_new_value) ON CONFLICT (employee_id) DO UPDATE SET name         = EXCLUDED.name;
    WHEN 'ec.relationship' THEN INSERT INTO emergency_contacts (employee_id, name, relationship)     VALUES (p_employee_id, '',           p_new_value) ON CONFLICT (employee_id) DO UPDATE SET relationship = EXCLUDED.relationship;
    WHEN 'ec.phone'        THEN INSERT INTO emergency_contacts (employee_id, name, phone)            VALUES (p_employee_id, '',           p_new_value) ON CONFLICT (employee_id) DO UPDATE SET phone        = EXCLUDED.phone;
    WHEN 'ec.alt_phone'    THEN INSERT INTO emergency_contacts (employee_id, name, alt_phone)        VALUES (p_employee_id, '',           p_new_value) ON CONFLICT (employee_id) DO UPDATE SET alt_phone    = EXCLUDED.alt_phone;
    WHEN 'ec.email'        THEN INSERT INTO emergency_contacts (employee_id, name, email)            VALUES (p_employee_id, '',           p_new_value) ON CONFLICT (employee_id) DO UPDATE SET email        = EXCLUDED.email;

    -- Read-only / computed — silently ignore
    WHEN 'emp.employee_id', 'emp.status', 'emp.base_currency_id' THEN NULL;

    ELSE
      RAISE EXCEPTION 'Unknown field key: %', p_field_key
        USING ERRCODE = 'invalid_parameter_value';
  END CASE;
END;
$$;

REVOKE ALL     ON FUNCTION update_hire_field(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION update_hire_field(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION update_hire_field(uuid, text, text) IS
  'Update a single field on a hire-pipeline employee record. '
  'Mig 347: emp.hire_date now re-anchors employee_personal.effective_from to the '
  'new hire date via upsert_personal_info({}, new_date). Prevents the nightly '
  'effective-dating sweep from snapping the personal row back to the old date. '
  'Mig 563 fix 1: passport.number added as alias for passport.passport_number — '
  'get_employee_hire_review emits passport.number (mig 406+) but update_hire_field '
  'previously only handled passport.passport_number, causing Unknown field key error. '
  'Mig 563 fix 2: ec.relationship/phone/alt_phone/email INSERTs now supply name='''' '
  'so a fresh row satisfies the NOT NULL constraint on emergency_contacts.name.';
