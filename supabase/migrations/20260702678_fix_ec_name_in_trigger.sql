-- =============================================================================
-- Mig 678: fix emergency contact name not updating via workflow approval
--
-- ROOT CAUSE
-- ----------
-- The Supabase JS client strips null values from JSONB parameters before sending
-- to PostgREST. In saveEmergency(), the proposed object was built as:
--   { name: fd('ecName') || null, ... }
-- If ecName resolved to '' (empty string), '' || null = null, and the Supabase
-- client dropped the 'name' key from the JSONB entirely. So proposed_data never
-- contained 'name', and the trigger's COALESCE(v_data->>'name', name) fell back
-- to the existing value — name never changed even when the user edited it.
--
-- FIX
-- ---
-- Frontend (MyProfile/index.tsx): changed `fd('ecName') || null` to
-- `fd('ecName') || ''` so the key is always present in the JSON as a string.
--
-- Trigger (this migration): use NULLIF(v_data->>'name', '') so that an explicit
-- empty string from the frontend is treated the same as a missing key (preserves
-- existing name), while a real name value (non-empty string) is applied.
-- =============================================================================

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

  -- Signal to upsert_* functions that this is a system/trigger context.
  PERFORM set_config('prowess.trigger_context', 'true', true);

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
    SELECT id INTO v_ec_record_id FROM emergency_contacts WHERE employee_id = v_emp_id LIMIT 1;
    IF v_ec_record_id IS NULL AND NEW.record_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM emergency_contacts WHERE id = NEW.record_id) THEN
      v_ec_record_id := NEW.record_id;
    END IF;
    IF v_ec_record_id IS NOT NULL THEN
      UPDATE emergency_contacts SET
        -- NULLIF(...,'') handles both missing key (NULL) and empty string sent by frontend
        name         = COALESCE(NULLIF(v_data->>'name',         ''), name),
        relationship = COALESCE(NULLIF(v_data->>'relationship', ''), relationship),
        phone        = COALESCE(NULLIF(v_data->>'phone',        ''), phone),
        alt_phone    = COALESCE(NULLIF(v_data->>'alt_phone',    ''), alt_phone),
        email        = COALESCE(NULLIF(v_data->>'email',        ''), email),
        updated_at   = now()
      WHERE id = v_ec_record_id;
    ELSE
      INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
      VALUES (v_emp_id,
              NULLIF(v_data->>'name',         ''),
              NULLIF(v_data->>'relationship', ''),
              NULLIF(v_data->>'phone',        ''),
              NULLIF(v_data->>'alt_phone',    ''),
              NULLIF(v_data->>'email',        ''));
    END IF;

  ELSIF v_module = 'profile_dependents' THEN
    DECLARE
      v_dep_items  jsonb;
      v_dep_eff    date;
      v_dep_target uuid;
      v_set_id     uuid;
    BEGIN
      v_dep_items := v_data->'items';
      IF jsonb_typeof(v_dep_items) <> 'array' THEN
        RAISE WARNING 'apply_profile_pending_change: profile_dependents pending_change=% has no items[]; skipping.', NEW.id;
      ELSE
        v_dep_eff    := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
        v_dep_target := COALESCE(NULLIF(v_data->>'employee_id','')::uuid, v_emp_id);
        BEGIN
          v_set_id := fn_apply_dependent_set_transition(
            p_employee_id    => v_dep_target,
            p_effective_from => v_dep_eff,
            p_items          => v_dep_items,
            p_actor          => NEW.submitted_by
          );
          RAISE NOTICE 'apply_profile_pending_change: applied dependent set pending_change=% set_id=% employee=%',
            NEW.id, v_set_id, v_dep_target;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'apply_profile_pending_change: fn_apply_dependent_set_transition failed pending_change=% employee=% error=%',
            NEW.id, v_dep_target, SQLERRM;
        END;
      END IF;
    END;

  ELSIF v_module = 'profile_bank' THEN
    NULL; -- handled by dedicated apply function (fn_apply_bank_set_transition)

  ELSE
    RAISE NOTICE 'apply_profile_pending_change: unhandled module_code=% for pending_change=%', v_module, NEW.id;
  END IF;

  RETURN NEW;

END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'Mig 661: correct column names; employee resolution via record_id / subject_profile_id / submitted_by fallback. '
  'Mig 662: education calls pass p_force_path_a=true to prevent workflow re-entry loop. '
  'Mig 667: passport, identification, emergency_contact look up satellite row by employee_id first. '
  'Mig 670: emergency_contact UPDATE/INSERT includes alt_phone. '
  'Mig 672: profile_dependents branch restored — calls fn_apply_dependent_set_transition. '
  'Mig 676/677: set prowess.trigger_context=true so upsert functions bypass approver permission checks. '
  'Mig 678: emergency_contact name uses NULLIF(...,'''') — Supabase JS strips null JSONB keys so '
  'frontend now sends empty string; NULLIF treats empty string same as missing key.';
