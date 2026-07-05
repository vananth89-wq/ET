-- Migration 662 — upsert_education / remove_education: enforce workflow path
--               for active employees when a workflow assignment exists
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM
-- ───────
-- v_is_path_a in upsert_education is true whenever the caller has
-- education.edit or education.create — so HR users always write directly,
-- bypassing the profile_education workflow even when one is assigned.
--
-- Additionally, submit_change_request was called without p_subject_employee_id,
-- so for on-behalf-of submissions the subject_profile_id on the workflow
-- instance pointed to the HR actor, not the target employee.
--
-- INFINITE LOOP RISK
-- ──────────────────
-- apply_profile_pending_change (trigger) calls upsert_education after approval.
-- If upsert_education re-evaluates Path A/B, it would go PATH B again for
-- active employees, creating a new pending change → loop.
-- Fix: add p_force_path_a boolean DEFAULT false. Trigger passes true.
--
-- FIX
-- ───
-- 1. Force Path B (workflow) when:
--      a) p_force_path_a = false (not called from trigger), AND
--      b) the target employee is ACTIVE (not Draft/Incomplete/Pending), AND
--      c) a workflow assignment exists for profile_education
--    Path A is still used for hire pipeline, no-assignment, or trigger calls.
-- 2. Pass p_subject_employee_id => p_employee_id to submit_change_request.
-- 3. Update apply_profile_pending_change to pass p_force_path_a => true.

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid    DEFAULT NULL,
  p_force_path_a   boolean DEFAULT false   -- set true when called from trigger
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              uuid  := auth.uid();
  v_is_path_a          boolean;
  v_is_hire            boolean;
  v_has_wf_assignment  boolean;
  v_edu_id             uuid;
  v_education_level    text;
  v_degree             text;
  v_institution        text;
  v_start_date         date;
  v_end_date           date;
  v_completion_status  text;
  v_grade_or_gpa       text;
  v_is_highest         boolean;
  v_att                jsonb;
  v_att_id             uuid;
  v_submit_result      jsonb;
BEGIN

  -- ── Access check ─────────────────────────────────────────────────────────────
  IF NOT (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR user_can('education', 'view',   p_employee_id)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- ── Hire pipeline? ───────────────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── Workflow assignment exists? ───────────────────────────────────────────────
  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);

  -- ── Path resolution ──────────────────────────────────────────────────────────
  -- PATH A (direct write): forced (trigger), hire pipeline, or no workflow configured
  -- PATH B (workflow):     normal call + active employee + workflow assignment
  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  -- ── Extract + validate fields ────────────────────────────────────────────────
  v_education_level   := p_education_data->>'education_level';
  v_degree            := NULLIF(trim(p_education_data->>'degree'),       '');
  v_institution       := NULLIF(trim(p_education_data->>'institution'),  '');
  v_start_date        := NULLIF(p_education_data->>'start_date', '')::date;
  v_end_date          := NULLIF(p_education_data->>'end_date',   '')::date;
  v_completion_status := p_education_data->>'completion_status';
  v_grade_or_gpa      := NULLIF(trim(p_education_data->>'grade_or_gpa'), '');
  v_is_highest        := COALESCE((p_education_data->>'is_highest_qualification')::boolean, false);

  IF v_education_level IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'education_level is required.');
  END IF;
  IF v_degree IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'degree is required.');
  END IF;
  IF v_institution IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'institution is required.');
  END IF;
  IF v_start_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'start_date is required.');
  END IF;
  IF v_completion_status IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'completion_status is required.');
  END IF;
  IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'end_date must be on or after start_date.');
  END IF;
  IF v_completion_status = 'ES01' THEN
    IF v_end_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date is required for Completed qualifications.');
    END IF;
    IF v_end_date > CURRENT_DATE THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date cannot be in the future for Completed qualifications.');
    END IF;
  END IF;

  -- ── PATH B: stage via workflow ───────────────────────────────────────────────
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => p_education_data,
      p_action              => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END,
      p_subject_employee_id => p_employee_id   -- mig 662: stamp correct subject
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- ── PATH A: direct write ─────────────────────────────────────────────────────
  IF v_is_highest THEN
    UPDATE employee_education
    SET    is_highest_qualification = false, updated_by = v_actor, updated_at = NOW()
    WHERE  employee_id = p_employee_id AND is_highest_qualification = true
      AND  is_active = true
      AND  (p_education_id IS NULL OR id <> p_education_id);
  END IF;

  IF p_education_id IS NOT NULL THEN
    UPDATE employee_education SET
      education_level          = v_education_level,
      degree                   = v_degree,
      institution              = v_institution,
      start_date               = v_start_date,
      end_date                 = v_end_date,
      completion_status        = v_completion_status,
      grade_or_gpa             = v_grade_or_gpa,
      is_highest_qualification = v_is_highest,
      updated_by               = v_actor,
      updated_at               = NOW()
    WHERE id = p_education_id AND employee_id = p_employee_id AND is_active = true
    RETURNING id INTO v_edu_id;

    IF v_edu_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already deleted.');
    END IF;
  ELSE
    INSERT INTO employee_education (
      employee_id, education_level, degree, institution,
      start_date, end_date, completion_status, grade_or_gpa,
      is_highest_qualification, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_education_level, v_degree, v_institution,
      v_start_date, v_end_date, v_completion_status, v_grade_or_gpa,
      v_is_highest, true, v_actor, v_actor
    ) RETURNING id INTO v_edu_id;
  END IF;

  -- ── Handle attachments (Path A only) ─────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(COALESCE(p_education_data->'attachments', '[]'::jsonb))
  LOOP
    v_att_id := (v_att->>'id')::uuid;
    IF v_att_id IS NOT NULL THEN
      UPDATE employee_education_attachments SET
        doc_type   = COALESCE(NULLIF(v_att->>'doc_type', ''), doc_type),
        updated_at = NOW()
      WHERE id = v_att_id AND education_id = v_edu_id;
    ELSE
      INSERT INTO employee_education_attachments (education_id, employee_id, file_name, file_path, doc_type, uploaded_by)
      VALUES (v_edu_id, p_employee_id,
              v_att->>'file_name', v_att->>'file_path',
              NULLIF(v_att->>'doc_type', ''), v_actor)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'workflow', false, 'education_id', v_edu_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid, boolean) TO authenticated;


-- ── remove_education: same workflow-path fix ──────────────────────────────────

CREATE OR REPLACE FUNCTION remove_education(
  p_employee_id  uuid,
  p_education_id uuid,
  p_force_path_a boolean DEFAULT false   -- set true when called from trigger
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor             uuid := auth.uid();
  v_is_hire           boolean;
  v_has_wf_assignment boolean;
  v_is_path_a         boolean;
  v_submit_result     jsonb;
BEGIN
  IF NOT (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'edit',   NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM employee_education
    WHERE id = p_education_id AND employee_id = p_employee_id AND is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already deleted.');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);
  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => jsonb_build_object('_operation', 'remove', 'education_id', p_education_id),
      p_action              => 'delete',
      p_subject_employee_id => p_employee_id   -- mig 662: correct subject
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- Path A: direct soft-delete
  UPDATE employee_education
  SET is_active = false, updated_by = v_actor, updated_at = NOW()
  WHERE id = p_education_id AND employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'workflow', false);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION remove_education(uuid, uuid, boolean) TO authenticated;


-- ── Update apply_profile_pending_change to pass p_force_path_a => true ────────
-- This prevents the trigger from looping back into Path B when it calls
-- upsert_education / remove_education after an education change is approved.

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

  -- ── Step 1: record_id = employees.id (personal, contact, employment, …) ──────
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

  -- ── Step 3: fallback — submitted_by (self-service and legacy rows) ────────────
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
    -- p_force_path_a => true: prevents re-entering workflow path from trigger
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
    -- Look up by employee_id first (not record_id which is employees.id for address)
    SELECT id INTO v_addr_record_id
    FROM   employee_addresses
    WHERE  employee_id = v_emp_id
    LIMIT  1;
    -- Fallback: record_id is the satellite row id itself (legacy)
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
    IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM passports WHERE id = NEW.record_id) THEN
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
    IF NEW.record_id IS NOT NULL AND EXISTS (SELECT 1 FROM emergency_contacts WHERE id = NEW.record_id) THEN
      v_ec_record_id := NEW.record_id;
    END IF;
    IF v_ec_record_id IS NOT NULL THEN
      UPDATE emergency_contacts SET
        name         = COALESCE(v_data->>'name',         name),
        relationship = COALESCE(v_data->>'relationship', relationship),
        phone        = COALESCE(v_data->>'phone',        phone),
        email        = COALESCE(v_data->>'email',        email),
        updated_at   = now()
      WHERE id = v_ec_record_id;
    ELSE
      INSERT INTO emergency_contacts (employee_id, name, relationship, phone, email)
      VALUES (v_emp_id, v_data->>'name', v_data->>'relationship', v_data->>'phone', v_data->>'email');
    END IF;

  ELSIF v_module IN ('profile_bank', 'profile_dependents') THEN
    NULL; -- handled by dedicated apply functions

  ELSE
    RAISE NOTICE 'apply_profile_pending_change: unhandled module_code=% for pending_change=%', v_module, NEW.id;
  END IF;

  RETURN NEW;

END;
$$;

COMMENT ON FUNCTION upsert_education(uuid, jsonb, uuid, boolean) IS
  'Mig 662: Path A only for hire pipeline, no-assignment, or p_force_path_a=true. '
  'Active employee edits always route through workflow (Path B) when profile_education '
  'has a workflow_assignment. p_subject_employee_id passed to submit_change_request.';

COMMENT ON FUNCTION remove_education(uuid, uuid, boolean) IS
  'Mig 662: Same workflow-path logic as upsert_education. '
  'p_force_path_a=true used by trigger to bypass workflow after approval.';

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'Trigger on workflow_pending_changes: fires when status → approved. '
  'Mig 661: correct column names (pin not pincode, country not country_of_issue, expiry not expiry_date). '
  'Mig 661: employee resolution: record_id → subject_profile_id → submitted_by fallback. '
  'Mig 661: address looked up by employee_id first (not record_id). '
  'Mig 662: education calls pass p_force_path_a=true to prevent workflow re-entry loop.';
