-- ============================================================
-- Mig 620: personal_info — Insert mode, propagation, workflow
-- 1. Seed personal_info.create permission
-- 2. upsert_personal_info: add CORRECTION case + p_propagate
-- 3. upsert_personal_info_from_workflow wrapper
-- 4. apply_profile_pending_change: use wrapper for profile_personal
-- ============================================================

-- ── 1. Seed personal_info.create permission ───────────────────────────────
DO $$
DECLARE
  v_module_id uuid;
BEGIN
  SELECT id INTO v_module_id FROM modules WHERE code = 'personal_info';

  IF v_module_id IS NULL THEN
    RAISE NOTICE 'personal_info module not found — skipping personal_info.create seed';
    RETURN;
  END IF;

  INSERT INTO permissions (code, module_id, action, name, description, sort_order)
  VALUES (
    'personal_info.create',
    v_module_id,
    'create',
    'Personal Info — Insert Slice',
    'Insert a new effective-dated personal information record.',
    15
  )
  ON CONFLICT (code) DO NOTHING;

  RAISE NOTICE 'personal_info.create permission seeded.';
END $$;

-- ── 2. upsert_personal_info — CORRECTION case + p_propagate ──────────────
CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date,
  p_propagate      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exact_row     employee_personal%ROWTYPE;
  v_current_row   employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_case          text;   -- 'correction' | 'prepend' | 'amendment' | 'gap_fill'
  v_is_hire       boolean;
  v_is_system_path boolean := false;

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
BEGIN

  -- ── 1a. Access guard (Layer-A coarse) ─────────────────────────────────────
  -- System paths: hire pipeline approvers, resubmission actors, bulk import
  IF user_can('personal_info', 'bulk_import', NULL) THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.entity_id   = p_employee_id
        AND wi.module_code IN ('employee_hire','employee_onboarding')
        AND wi.status      IN ('draft','pending','incomplete')
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_task_assignments wta
      JOIN workflow_instances wi ON wi.id = wta.instance_id
      WHERE wi.entity_id  = p_employee_id
        AND wta.assignee_id = auth.uid()
        AND wta.status      = 'pending'
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.entity_id   = p_employee_id
        AND wi.status      = 'awaiting_clarification'
        AND wi.initiated_by = auth.uid()
    ) THEN v_is_system_path := true; END IF;
  END IF;
  -- Legacy workflow path (old schema)
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id   = p_employee_id
        AND wt.assigned_to = auth.uid()
        AND wt.status      = 'pending'
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id    = p_employee_id
        AND wi.submitted_by = auth.uid()
        AND wi.status       = 'awaiting_clarification'
    ) THEN v_is_system_path := true; END IF;
  END IF;

  IF NOT v_is_system_path THEN
    IF NOT (
      user_can('personal_info', 'edit',   p_employee_id)
      OR user_can('personal_info', 'create', p_employee_id)
      OR (p_employee_id = get_my_employee_id()
          AND (has_permission('personal_info.edit') OR has_permission('personal_info.create')))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: you do not have permission to edit personal information for this employee.');
    END IF;
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Detect hire pipeline ────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── 4. Case detection ──────────────────────────────────────────────────────
  -- CORRECTION: exact date match on an existing slice → update in place
  SELECT * INTO v_exact_row
  FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN
    v_case := 'correction';
  END IF;

  IF v_case IS NULL THEN
    -- PREPEND: before the earliest record
    DECLARE v_first employee_personal%ROWTYPE; BEGIN
      SELECT * INTO v_first FROM employee_personal
      WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
      IF FOUND AND p_effective_from < v_first.effective_from THEN
        v_case := 'prepend';
        v_current_row := v_first;
      END IF;
    END;
  END IF;

  IF v_case IS NULL THEN
    -- AMENDMENT or GAP_FILL: check open-ended row
    SELECT * INTO v_current_row
    FROM employee_personal
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true
    FOR UPDATE;
    IF FOUND THEN
      v_case := 'amendment';
    ELSE
      v_case := 'gap_fill';
    END IF;
  END IF;

  -- ── 1b. Layer-B fine-grained access guard ─────────────────────────────────
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      IF NOT (
        user_can('personal_info', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('personal_info.edit'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: personal_info.edit permission is required to edit an existing record.');
      END IF;
    ELSE
      IF NOT (
        user_can('personal_info', 'create', p_employee_id)
        OR user_can('personal_info', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id()
            AND (has_permission('personal_info.create') OR has_permission('personal_info.edit')))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: personal_info.create permission is required to insert a new personal info record.');
      END IF;
    END IF;
  END IF;

  -- ── 5. Derive name fields ──────────────────────────────────────────────────
  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  v_exact_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, v_exact_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   v_exact_row.last_name,   '')), '');
  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  -- ── 6. Execute by case ────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    -- In-place update of the matching slice
    UPDATE employee_personal SET
      first_name     = v_first_name,
      middle_name    = v_middle_name,
      last_name      = v_last_name,
      name           = v_computed_name,
      nationality    = COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_exact_row.nationality),
      marital_status = COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_exact_row.marital_status),
      gender         = COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_exact_row.gender),
      dob            = COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_exact_row.dob),
      photo_url      = COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_exact_row.photo_url),
      updated_at     = NOW(), updated_by = auth.uid()
    WHERE id = v_exact_row.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    -- Insert a new slice before the earliest existing one
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
      p_effective_from,
      v_current_row.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'amendment' THEN
    IF v_is_hire THEN
      -- Hire pipeline: replace in place (no historical slice)
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSIF v_current_row.effective_from >= p_effective_from THEN
      -- Effective date moved backwards → replace the current row entirely
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSE
      -- Active employee amendment: close the current slice
      IF EXISTS (
        SELECT 1 FROM employee_personal
        WHERE employee_id  = p_employee_id
          AND is_active    = true
          AND effective_to < '9999-12-31'::date
          AND effective_to >= p_effective_from
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'The chosen effective date overlaps with an existing historical record. Choose a later date.');
      END IF;
      UPDATE employee_personal
      SET effective_to = p_effective_from - interval '1 day',
          updated_by = auth.uid(), updated_at = NOW()
      WHERE id = v_current_row.id;
    END IF;
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
      p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSE -- gap_fill
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      NULLIF(p_proposed_data->>'nationality',    ''),
      NULLIF(p_proposed_data->>'marital_status', ''),
      NULLIF(p_proposed_data->>'gender',         ''),
      NULLIF(p_proposed_data->>'dob',            '')::date,
      NULLIF(p_proposed_data->>'photo_url',      ''),
      p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 7. Propagation ────────────────────────────────────────────────────────
  -- When p_propagate=true, push explicitly-provided fields to all future slices.
  -- dob and photo_url are excluded — point-in-time / static facts.
  IF p_propagate THEN
    UPDATE employee_personal SET
      first_name = CASE
        WHEN (p_proposed_data ? 'first_name') AND NULLIF(p_proposed_data->>'first_name','') IS NOT NULL
        THEN v_first_name ELSE first_name END,
      middle_name = CASE
        WHEN (p_proposed_data ? 'middle_name')
        THEN v_middle_name ELSE middle_name END,
      last_name = CASE
        WHEN (p_proposed_data ? 'last_name') AND NULLIF(p_proposed_data->>'last_name','') IS NOT NULL
        THEN v_last_name ELSE last_name END,
      name = CASE
        WHEN (p_proposed_data ? 'first_name') OR (p_proposed_data ? 'last_name')
        THEN v_computed_name ELSE name END,
      nationality = CASE
        WHEN (p_proposed_data ? 'nationality') AND NULLIF(p_proposed_data->>'nationality','') IS NOT NULL
        THEN p_proposed_data->>'nationality' ELSE nationality END,
      marital_status = CASE
        WHEN (p_proposed_data ? 'marital_status') AND NULLIF(p_proposed_data->>'marital_status','') IS NOT NULL
        THEN p_proposed_data->>'marital_status' ELSE marital_status END,
      gender = CASE
        WHEN (p_proposed_data ? 'gender') AND NULLIF(p_proposed_data->>'gender','') IS NOT NULL
        THEN p_proposed_data->>'gender' ELSE gender END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 8. Sync employees.name ────────────────────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    UPDATE employees
    SET name = v_computed_name, updated_at = NOW()
    WHERE id = p_employee_id
      AND (name IS DISTINCT FROM v_computed_name);
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_new_id, 'case', v_case);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) IS
  'Mig 620: CORRECTION case (exact date match → in-place UPDATE), PREPEND, AMENDMENT, GAP_FILL. '
  'p_propagate=true pushes explicitly-changed fields (excl. dob, photo_url) to all future slices. '
  'personal_info.create permission required for non-correction cases.';

-- ── 3. Workflow wrapper ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_personal_info_from_workflow(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_propagate boolean;
BEGIN
  v_propagate := COALESCE((p_proposed_data->>'_propagate')::boolean, false);
  RETURN upsert_personal_info(p_employee_id, p_proposed_data, p_effective_from, v_propagate);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_personal_info_from_workflow(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info_from_workflow(uuid, jsonb, date) IS
  'Mig 620: workflow approval wrapper — reads _propagate from proposed_data JSONB '
  'and passes it to upsert_personal_info. Used by apply_profile_pending_change.';

-- ── 4. Patch apply_profile_pending_change — profile_personal branch ────────
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

  SELECT p.employee_id INTO v_emp_id FROM profiles p WHERE p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING 'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
  END IF;

  IF v_module = 'profile_personal' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    -- Mig 620: use wrapper that reads _propagate from proposed_data
    v_result   := upsert_personal_info_from_workflow(v_emp_id, v_data, v_eff_from);
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING 'apply_profile_pending_change: upsert_personal_info failed for employee=%, error=%', v_emp_id, v_result->>'error';
    END IF;

  ELSIF v_module = 'profile_employment' THEN
    v_eff_from := COALESCE(NULLIF(v_data->>'effective_from','')::date, CURRENT_DATE);
    -- Mig 616: use wrapper that reads _propagate from proposed_data
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
    IF NEW.record_id IS NOT NULL THEN
      UPDATE employee_addresses SET
        address_type = COALESCE(v_data->>'address_type', address_type),
        line1 = COALESCE(v_data->>'line1', line1), line2 = COALESCE(v_data->>'line2', line2),
        city  = COALESCE(v_data->>'city',  city),  state = COALESCE(v_data->>'state', state),
        country = COALESCE(v_data->>'country', country), pincode = COALESCE(v_data->>'pincode', pincode),
        updated_at = now()
      WHERE id = NEW.record_id AND employee_id = v_emp_id;
    ELSE
      INSERT INTO employee_addresses (employee_id, address_type, line1, line2, city, state, country, pincode)
      VALUES (v_emp_id, v_data->>'address_type', v_data->>'line1', v_data->>'line2',
              v_data->>'city', v_data->>'state', v_data->>'country', v_data->>'pincode');
    END IF;

  ELSIF v_module = 'profile_passport' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE passports SET
        passport_number  = COALESCE(v_data->>'passport_number',  passport_number),
        country_of_issue = COALESCE(v_data->>'country_of_issue', country_of_issue),
        issue_date       = COALESCE(NULLIF(v_data->>'issue_date', '')::date,  issue_date),
        expiry_date      = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at = now()
      WHERE id = NEW.record_id AND employee_id = v_emp_id;
    ELSE
      INSERT INTO passports (employee_id, passport_number, country_of_issue, issue_date, expiry_date)
      VALUES (v_emp_id, v_data->>'passport_number', v_data->>'country_of_issue',
              NULLIF(v_data->>'issue_date','')::date, NULLIF(v_data->>'expiry_date','')::date);
    END IF;

  ELSIF v_module = 'profile_identification' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE identity_records SET
        id_type = COALESCE(v_data->>'id_type', id_type), id_number = COALESCE(v_data->>'id_number', id_number),
        expiry_date = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date), updated_at = now()
      WHERE id = NEW.record_id AND employee_id = v_emp_id;
    ELSE
      INSERT INTO identity_records (employee_id, id_type, id_number, expiry_date)
      VALUES (v_emp_id, v_data->>'id_type', v_data->>'id_number', NULLIF(v_data->>'expiry_date','')::date);
    END IF;

  ELSIF v_module = 'profile_emergency_contact' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE emergency_contacts SET
        name = COALESCE(v_data->>'name', name), relationship = COALESCE(v_data->>'relationship', relationship),
        phone = COALESCE(v_data->>'phone', phone), email = COALESCE(v_data->>'email', email), updated_at = now()
      WHERE id = NEW.record_id AND employee_id = v_emp_id;
    ELSE
      INSERT INTO emergency_contacts (employee_id, name, relationship, phone, email)
      VALUES (v_emp_id, v_data->>'name', v_data->>'relationship', v_data->>'phone', v_data->>'email');
    END IF;

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
  'Mig 616: profile_employment uses upsert_employment_info_from_workflow (reads _propagate). '
  'Mig 620: profile_personal uses upsert_personal_info_from_workflow (reads _propagate).';
