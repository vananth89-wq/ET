-- Migration 668 — Add alt_phone to emergency_contact block in apply_profile_pending_change
-- The trigger was missing alt_phone in both UPDATE and INSERT, so alternate phone
-- changes from workflow approvals were silently dropped.

CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_module         text;
  v_data           jsonb;
  v_emp_id         uuid;
  v_result         jsonb;
  v_eff_from       date;
  v_old_set_id     uuid;
  v_addr_record_id uuid;
  v_pass_record_id uuid;
  v_id_record_id   uuid;
  v_ec_record_id   uuid;
BEGIN
  IF NEW.status != 'approved' OR OLD.status = 'approved' THEN RETURN NEW; END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- ── Step 1: record_id = employees.id ─────────────────────────────────────────
  IF NEW.record_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM employees WHERE id = NEW.record_id) THEN
      v_emp_id := NEW.record_id;
    END IF;
  END IF;

  -- ── Step 2: subject_profile_id from workflow_instances (on-behalf-of) ─────────
  IF v_emp_id IS NULL AND NEW.instance_id IS NOT NULL THEN
    SELECT p.employee_id INTO v_emp_id
    FROM   workflow_instances wi
    JOIN   profiles           p  ON p.id = wi.subject_profile_id
    WHERE  wi.id = NEW.instance_id
      AND  wi.subject_profile_id IS NOT NULL;
  END IF;

  -- ── Step 3: fallback — submitted_by ──────────────────────────────────────────
  IF v_emp_id IS NULL THEN
    SELECT p.employee_id INTO v_emp_id
    FROM   profiles p
    WHERE  p.id = NEW.submitted_by;
  END IF;

  IF v_emp_id IS NULL THEN
    RAISE WARNING 'apply_profile_pending_change: cannot resolve employee_id '
      'for submitted_by=%, record_id=%, instance_id=%, module=%, pending_change=%',
      NEW.submitted_by, NEW.record_id, NEW.instance_id, v_module, NEW.id;
    RETURN NEW;
  END IF;

  -- ── Apply changes per module ───────────────────────────────────────────────────

  IF v_module = 'profile_personal' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    v_result   := upsert_personal_info_from_workflow(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_personal_info failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    END IF;

  ELSIF v_module = 'profile_employment' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    v_result   := upsert_employment_info_from_workflow(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_employment_info failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    END IF;

  ELSIF v_module = 'profile_job_relationships' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    SELECT id INTO v_old_set_id
    FROM   employee_job_relationship_set
    WHERE  employee_id = v_emp_id AND is_active = true AND effective_to = '9999-12-31'::date;
    v_result := upsert_job_relationship_set(v_emp_id, v_eff_from, COALESCE(v_data->'items','[]'::jsonb));
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_job_relationship_set failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    ELSE
      BEGIN
        PERFORM fn_queue_job_relationship_notifications(v_emp_id, (v_result->>'set_id')::uuid, v_old_set_id, NEW.submitted_by);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'apply_profile_pending_change: notification queuing failed for employee=%, error=%',
          v_emp_id, SQLERRM;
      END;
    END IF;

  ELSIF v_module = 'profile_education' THEN
    IF v_data->>'_operation' = 'remove' THEN
      v_result := remove_education(v_emp_id, (v_data->>'education_id')::uuid, true);
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING 'apply_profile_pending_change: remove_education failed for employee=%, error=%',
          v_emp_id, v_result->>'error';
      END IF;
    ELSE
      v_result := upsert_education(v_emp_id, v_data, NEW.record_id, true);
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING 'apply_profile_pending_change: upsert_education failed for employee=%, error=%',
          v_emp_id, v_result->>'error';
      END IF;
    END IF;

  ELSIF v_module = 'profile_contact' THEN
    INSERT INTO employee_contact (employee_id, country_code, mobile, personal_email)
    VALUES (v_emp_id, v_data->>'country_code', v_data->>'mobile', v_data->>'personal_email')
    ON CONFLICT (employee_id) DO UPDATE SET
      country_code   = EXCLUDED.country_code,
      mobile         = EXCLUDED.mobile,
      personal_email = EXCLUDED.personal_email;

  ELSIF v_module = 'profile_address' THEN
    SELECT id INTO v_addr_record_id FROM employee_addresses WHERE employee_id = v_emp_id LIMIT 1;
    IF v_addr_record_id IS NULL AND NEW.record_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM employee_addresses WHERE id = NEW.record_id) THEN
      v_addr_record_id := NEW.record_id;
    END IF;
    IF v_addr_record_id IS NOT NULL THEN
      UPDATE employee_addresses SET
        line1      = COALESCE(v_data->>'line1',    line1),
        line2      = COALESCE(v_data->>'line2',    line2),
        city       = COALESCE(v_data->>'city',     city),
        state      = COALESCE(v_data->>'state',    state),
        country    = COALESCE(v_data->>'country',  country),
        pin        = COALESCE(v_data->>'pin',      v_data->>'pincode', pin),
        landmark   = COALESCE(v_data->>'landmark', landmark),
        district   = COALESCE(v_data->>'district', district),
        updated_at = now()
      WHERE id = v_addr_record_id;
    ELSE
      INSERT INTO employee_addresses (employee_id, line1, line2, city, state, country, pin, landmark, district)
      VALUES (v_emp_id, v_data->>'line1', v_data->>'line2',
              v_data->>'city', v_data->>'state', v_data->>'country',
              COALESCE(v_data->>'pin', v_data->>'pincode'),
              v_data->>'landmark', v_data->>'district');
    END IF;

  ELSIF v_module = 'profile_passport' THEN
    SELECT id INTO v_pass_record_id FROM passports WHERE employee_id = v_emp_id LIMIT 1;
    IF v_pass_record_id IS NULL AND NEW.record_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM passports WHERE id = NEW.record_id) THEN
      v_pass_record_id := NEW.record_id;
    END IF;
    IF v_pass_record_id IS NOT NULL THEN
      UPDATE passports SET
        passport_number = COALESCE(v_data->>'passport_number', passport_number),
        country         = COALESCE(v_data->>'country_of_issue', v_data->>'country', country),
        issue_date      = COALESCE(NULLIF(v_data->>'issue_date', '')::date,  issue_date),
        expiry_date     = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at      = now()
      WHERE id = v_pass_record_id;
    ELSE
      INSERT INTO passports (employee_id, passport_number, country, issue_date, expiry_date)
      VALUES (v_emp_id, v_data->>'passport_number',
              COALESCE(v_data->>'country_of_issue', v_data->>'country'),
              NULLIF(v_data->>'issue_date','')::date, NULLIF(v_data->>'expiry_date','')::date);
    END IF;

  ELSIF v_module = 'profile_identification' THEN
    IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM identity_records WHERE id = NEW.record_id) THEN
      v_id_record_id := NEW.record_id;
    ELSE
      SELECT id INTO v_id_record_id
      FROM   identity_records
      WHERE  employee_id = v_emp_id
      ORDER  BY created_at DESC LIMIT 1;
    END IF;
    IF v_id_record_id IS NOT NULL THEN
      UPDATE identity_records SET
        id_type    = COALESCE(v_data->>'id_type',   id_type),
        id_number  = COALESCE(v_data->>'id_number', id_number),
        expiry     = COALESCE(NULLIF(v_data->>'expiry_date','')::date, NULLIF(v_data->>'expiry','')::date, expiry),
        updated_at = now()
      WHERE id = v_id_record_id;
    ELSE
      INSERT INTO identity_records (employee_id, id_type, id_number, expiry)
      VALUES (v_emp_id, v_data->>'id_type', v_data->>'id_number',
              COALESCE(NULLIF(v_data->>'expiry_date','')::date, NULLIF(v_data->>'expiry','')::date));
    END IF;

  ELSIF v_module = 'profile_emergency_contact' THEN
    -- Look up by employee_id first; fall back to record_id as satellite UUID
    SELECT id INTO v_ec_record_id FROM emergency_contacts WHERE employee_id = v_emp_id LIMIT 1;
    IF v_ec_record_id IS NULL AND NEW.record_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM emergency_contacts WHERE id = NEW.record_id) THEN
      v_ec_record_id := NEW.record_id;
    END IF;
    IF v_ec_record_id IS NOT NULL THEN
      UPDATE emergency_contacts SET
        name         = COALESCE(v_data->>'name',         name),
        relationship = COALESCE(v_data->>'relationship', relationship),
        phone        = COALESCE(v_data->>'phone',        phone),
        alt_phone    = COALESCE(v_data->>'alt_phone',    alt_phone),
        email        = COALESCE(v_data->>'email',        email),
        updated_at   = now()
      WHERE id = v_ec_record_id;
    ELSE
      INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
      VALUES (v_emp_id, v_data->>'name', v_data->>'relationship',
              v_data->>'phone', v_data->>'alt_phone', v_data->>'email');
    END IF;

  ELSIF v_module IN ('profile_bank', 'profile_dependents') THEN
    NULL; -- handled by dedicated apply functions

  ELSE
    RAISE NOTICE 'apply_profile_pending_change: unhandled module_code=% for pending_change=%', v_module, NEW.id;
  END IF;

  RETURN NEW;

END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'Mig 661: correct column names; employee resolution via record_id / subject_profile_id / submitted_by. '
  'Mig 662: education calls pass p_force_path_a=true. '
  'Mig 667: passport/identification/emergency_contact look up by employee_id first. '
  'Mig 668: emergency_contact UPDATE/INSERT now includes alt_phone.';
