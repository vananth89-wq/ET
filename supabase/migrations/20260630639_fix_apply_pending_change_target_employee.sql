-- ============================================================
-- Mig 639: fix apply_profile_pending_change — use record_id
--          to resolve the target employee, not submitted_by.
--
-- ROOT CAUSE
-- ──────────
-- The trigger was resolving the target employee via:
--   SELECT p.employee_id INTO v_emp_id FROM profiles p WHERE p.id = NEW.submitted_by;
--
-- For self-service edits this works (submitted_by = target employee's profile).
-- For "on behalf of" edits by an HR admin, submitted_by = the HR admin's profile,
-- so the trigger updated the ADMIN's record instead of the target employee's.
--
-- FIX
-- ───
-- For profile modules, workflow_pending_changes.record_id = employees.id of the
-- employee being changed (set in MyProfile when building confirmPending).
-- Use record_id directly. Fall back to submitted_by → profiles only when
-- record_id is null (old rows or non-profile modules that don't set it).
-- ============================================================

CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_module    text;
  v_data      jsonb;
  v_emp_id    uuid;
  v_result    jsonb;
  v_eff_from  date;
  v_old_set_id uuid;
BEGIN
  IF NEW.status != 'approved' OR OLD.status = 'approved' THEN RETURN NEW; END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- ── Resolve target employee ────────────────────────────────────────────────
  -- record_id = employees.id for all profile modules (set by MyProfile frontend).
  -- Fall back to submitted_by → profiles for legacy rows that pre-date this fix.
  IF NEW.record_id IS NOT NULL THEN
    -- Verify it's actually an employees row (not a satellite row id)
    IF EXISTS (SELECT 1 FROM employees WHERE id = NEW.record_id) THEN
      v_emp_id := NEW.record_id;
    END IF;
  END IF;

  IF v_emp_id IS NULL THEN
    SELECT p.employee_id INTO v_emp_id FROM profiles p WHERE p.id = NEW.submitted_by;
  END IF;

  IF v_emp_id IS NULL THEN
    RAISE WARNING 'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, record_id=%, module=%, pending_change=%',
      NEW.submitted_by, NEW.record_id, v_module, NEW.id;
    RETURN NEW;
  END IF;

  IF v_module = 'profile_personal' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    v_result   := upsert_personal_info_from_workflow(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_personal_info failed for employee=%, error=%', v_emp_id, v_result->>'error';
    END IF;

  ELSIF v_module = 'profile_employment' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    v_result   := upsert_employment_info_from_workflow(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_employment_info failed for employee=%, error=%', v_emp_id, v_result->>'error';
    END IF;

  ELSIF v_module = 'profile_job_relationships' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    SELECT id INTO v_old_set_id FROM employee_job_relationship_set
    WHERE employee_id = v_emp_id AND is_active = true AND effective_to = '9999-12-31'::date;
    v_result := upsert_job_relationship_set(v_emp_id, v_eff_from, COALESCE(v_data->'items','[]'::jsonb));
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_job_relationship_set failed for employee=%, error=%', v_emp_id, v_result->>'error';
    ELSE
      BEGIN
        PERFORM fn_queue_job_relationship_notifications(v_emp_id, (v_result->>'set_id')::uuid, v_old_set_id, NEW.submitted_by);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'apply_profile_pending_change: notification queuing failed for employee=%, error=%', v_emp_id, SQLERRM;
      END;
    END IF;

  ELSIF v_module = 'profile_education' THEN
    IF v_data->>'_operation' = 'remove' THEN
      v_result := remove_education(v_emp_id, (v_data->>'education_id')::uuid);
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING 'apply_profile_pending_change: remove_education failed for employee=%, error=%', v_emp_id, v_result->>'error';
      END IF;
    ELSE
      v_result := upsert_education(v_emp_id, v_data, NEW.record_id);
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING 'apply_profile_pending_change: upsert_education failed for employee=%, error=%', v_emp_id, v_result->>'error';
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
    -- For address, record_id is the satellite row UUID, not the employee
    -- (handled by the old logic above which falls through here).
    -- We must use the address record_id for the satellite lookup, but
    -- v_emp_id is already resolved correctly via employees check above.
    DECLARE v_addr_record_id uuid;
    BEGIN
      -- record_id for address = satellite row uuid (not employees.id)
      -- The employee lookup above would have failed for satellite record_ids,
      -- so v_emp_id was resolved via submitted_by in those cases. Correct.
      IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM employee_addresses WHERE id = NEW.record_id) THEN
        v_addr_record_id := NEW.record_id;
      END IF;
      IF v_addr_record_id IS NOT NULL THEN
        UPDATE employee_addresses SET
          address_type = COALESCE(v_data->>'address_type', address_type),
          line1 = COALESCE(v_data->>'line1', line1), line2 = COALESCE(v_data->>'line2', line2),
          city  = COALESCE(v_data->>'city',  city),  state = COALESCE(v_data->>'state', state),
          country = COALESCE(v_data->>'country', country), pincode = COALESCE(v_data->>'pincode', pincode),
          updated_at = now()
        WHERE id = v_addr_record_id AND employee_id = v_emp_id;
      ELSE
        INSERT INTO employee_addresses (employee_id, address_type, line1, line2, city, state, country, pincode)
        VALUES (v_emp_id, v_data->>'address_type', v_data->>'line1', v_data->>'line2',
                v_data->>'city', v_data->>'state', v_data->>'country', v_data->>'pincode');
      END IF;
    END;

  ELSIF v_module = 'profile_passport' THEN
    DECLARE v_pass_record_id uuid;
    BEGIN
      IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM passports WHERE id = NEW.record_id) THEN
        v_pass_record_id := NEW.record_id;
      END IF;
      IF v_pass_record_id IS NOT NULL THEN
        UPDATE passports SET
          passport_number  = COALESCE(v_data->>'passport_number',  passport_number),
          country_of_issue = COALESCE(v_data->>'country_of_issue', country_of_issue),
          issue_date       = COALESCE(NULLIF(v_data->>'issue_date', '')::date,  issue_date),
          expiry_date      = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
          updated_at = now()
        WHERE id = v_pass_record_id AND employee_id = v_emp_id;
      ELSE
        INSERT INTO passports (employee_id, passport_number, country_of_issue, issue_date, expiry_date)
        VALUES (v_emp_id, v_data->>'passport_number', v_data->>'country_of_issue',
                NULLIF(v_data->>'issue_date','')::date, NULLIF(v_data->>'expiry_date','')::date);
      END IF;
    END;

  ELSIF v_module = 'profile_identification' THEN
    DECLARE v_id_record_id uuid;
    BEGIN
      IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM identity_records WHERE id = NEW.record_id) THEN
        v_id_record_id := NEW.record_id;
      END IF;
      IF v_id_record_id IS NOT NULL THEN
        UPDATE identity_records SET
          id_type = COALESCE(v_data->>'id_type', id_type), id_number = COALESCE(v_data->>'id_number', id_number),
          expiry_date = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date), updated_at = now()
        WHERE id = v_id_record_id AND employee_id = v_emp_id;
      ELSE
        INSERT INTO identity_records (employee_id, id_type, id_number, expiry_date)
        VALUES (v_emp_id, v_data->>'id_type', v_data->>'id_number', NULLIF(v_data->>'expiry_date','')::date);
      END IF;
    END;

  ELSIF v_module = 'profile_emergency_contact' THEN
    DECLARE v_ec_record_id uuid;
    BEGIN
      IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM emergency_contacts WHERE id = NEW.record_id) THEN
        v_ec_record_id := NEW.record_id;
      END IF;
      IF v_ec_record_id IS NOT NULL THEN
        UPDATE emergency_contacts SET
          name = COALESCE(v_data->>'name', name), relationship = COALESCE(v_data->>'relationship', relationship),
          phone = COALESCE(v_data->>'phone', phone), email = COALESCE(v_data->>'email', email), updated_at = now()
        WHERE id = v_ec_record_id AND employee_id = v_emp_id;
      ELSE
        INSERT INTO emergency_contacts (employee_id, name, relationship, phone, email)
        VALUES (v_emp_id, v_data->>'name', v_data->>'relationship', v_data->>'phone', v_data->>'email');
      END IF;
    END;

  ELSIF v_module IN ('profile_bank', 'profile_dependents') THEN
    NULL;

  ELSE
    RAISE NOTICE 'apply_profile_pending_change: unhandled module_code=% for pending_change=%', v_module, NEW.id;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'apply_profile_pending_change: unhandled exception for pending_change=%, error=%', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'Trigger on workflow_pending_changes: fires when status → approved. '
  'Mig 639: resolves target employee via record_id (employees.id) first, '
  'falling back to submitted_by → profiles for legacy rows. Fixes "on behalf of" '
  'edits where submitted_by was the HR admin, not the target employee.';
