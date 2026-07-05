-- =============================================================================
-- Mig 676: fix workflow approval not writing data when approver lacks permission
--
-- ROOT CAUSE
-- ----------
-- When an authenticated user (e.g. Naveen Elango) calls wf_approve via PostgREST,
-- the JWT is set at the session level. Even though apply_profile_pending_change is
-- SECURITY DEFINER, auth.uid() still returns the APPROVER'S profile ID inside the
-- trigger — not NULL. So the "auth.uid() IS NULL → system path" guard added in
-- mig 644 / 675 never fires.
--
-- Inside upsert_personal_info / upsert_employment_info, the permission check then
-- runs as if the approver is editing the record. If the approver doesn't have
-- personal_info.edit / employment.edit permission on the target employee (e.g.
-- Naveen can approve workflows but doesn't have HR edit permissions), user_can()
-- returns false → {ok: false, error: 'Access denied'} → trigger logs WARNING →
-- data silently not written.
--
-- FIX
-- ---
-- 1. apply_profile_pending_change sets a transaction-local config flag
--    'prowess.trigger_context' = 'true' before calling any upsert function.
-- 2. upsert_personal_info and upsert_employment_info check this flag in addition
--    to auth.uid() IS NULL. Either condition → v_is_system_path = true.
--
-- The 'prowess.trigger_context' flag is transaction-local (3rd arg = true in
-- set_config), so it cannot leak across requests. It follows the same pattern
-- as 'prowess.allow_name_sync' (mig 649) and 'prowess.allow_employment_sync'
-- (mig 675).
--
-- SAFETY
-- ------
-- apply_profile_pending_change is SECURITY DEFINER. It can only be reached via
-- the AFTER UPDATE trigger on workflow_pending_changes. No direct client path
-- can set this flag and then call an upsert function in the same transaction,
-- because PostgREST RPCs do not expose set_config to callers.
-- =============================================================================


-- =============================================================================
-- 1. apply_profile_pending_change — add prowess.trigger_context signal
--    (full rewrite from mig 672; only change = set_config call after guard)
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
  -- auth.uid() is set to the APPROVER's user ID (not NULL) in a PostgREST
  -- session — without this flag, upsert functions run permission checks as if
  -- the approver is the editor, which fails for approvers without edit rights.
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
        name         = COALESCE(v_data->>'name',         name),
        relationship = COALESCE(v_data->>'relationship', relationship),
        phone        = COALESCE(v_data->>'phone',        phone),
        alt_phone    = COALESCE(v_data->>'alt_phone',    alt_phone),
        email        = COALESCE(v_data->>'email',        email),
        updated_at   = now()
      WHERE id = v_ec_record_id;
    ELSE
      INSERT INTO emergency_contacts (employee_id, name, relationship, phone, alt_phone, email)
      VALUES (v_emp_id, v_data->>'name', v_data->>'relationship', v_data->>'phone',
              v_data->>'alt_phone', v_data->>'email');
    END IF;

  ELSIF v_module = 'profile_dependents' THEN
    -- ── Restored from mig 321 — was silently dropped in rewrites 661/667/670 ───
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
  'Mig 676: set prowess.trigger_context=true (txn-local) before each upsert call so that '
  'upsert functions bypass approver permission checks. Root cause: auth.uid() returns the '
  'APPROVER''s ID (not NULL) in PostgREST sessions, so non-HR approvers were blocked.';


-- =============================================================================
-- 2. upsert_personal_info — check prowess.trigger_context in addition to
--    auth.uid() IS NULL  (full rewrite from mig 649; only guard line changes)
-- =============================================================================

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
  v_exact_row      employee_personal%ROWTYPE;
  v_current_row    employee_personal%ROWTYPE;
  v_split_row      employee_personal%ROWTYPE;
  v_new_id         uuid;
  v_new_eff_to     date;
  v_case           text;
  v_is_hire        boolean;
  v_is_system_path boolean := false;

  v_first_name     text;
  v_middle_name    text;
  v_last_name      text;
  v_computed_name  text;
BEGIN

  -- ── 1a. Access guard ─────────────────────────────────────────────────────────
  -- No session (service role) OR called from apply_profile_pending_change trigger.
  -- The trigger sets prowess.trigger_context=true (txn-local) before calling us
  -- because auth.uid() is the APPROVER's ID in PostgREST sessions — not NULL —
  -- so non-HR approvers would otherwise fail the permission check.
  IF auth.uid() IS NULL
     OR current_setting('prowess.trigger_context', true) = 'true' THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path AND user_can('personal_info', 'bulk_import', NULL) THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id   = p_employee_id
        AND wi.module_code IN ('employee_hire','employee_onboarding')
        AND wi.status      IN ('draft','pending','incomplete')
    ) THEN v_is_system_path := true; END IF;
  END IF;
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

  -- ── 2. Input validation ──────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Detect hire pipeline ──────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── 4. Case detection ────────────────────────────────────────────────────────
  SELECT * INTO v_exact_row
  FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN
    v_case := 'correction';
  END IF;

  IF v_case IS NULL THEN
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
    SELECT * INTO v_current_row
    FROM employee_personal
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true
    FOR UPDATE;
    IF FOUND THEN v_case := 'amendment'; ELSE v_case := 'gap_fill'; END IF;
  END IF;

  -- ── 1b. Layer-B access guard (skipped for system paths) ─────────────────────
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      IF NOT (user_can('personal_info', 'edit', p_employee_id)
              OR (p_employee_id = get_my_employee_id() AND has_permission('personal_info.edit')))
      THEN RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: personal_info.edit permission is required to edit an existing record.'); END IF;
    ELSE
      IF NOT (user_can('personal_info', 'create', p_employee_id)
              OR user_can('personal_info', 'edit', p_employee_id)
              OR (p_employee_id = get_my_employee_id()
                  AND (has_permission('personal_info.create') OR has_permission('personal_info.edit'))))
      THEN RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: personal_info.create permission is required to insert a new personal info record.'); END IF;
    END IF;
  END IF;

  -- ── 5. Derive name fields ────────────────────────────────────────────────────
  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  v_exact_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, v_exact_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   v_exact_row.last_name,   '')), '');
  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  -- ── 6. Execute by case ───────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
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
      p_effective_from, v_current_row.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'amendment' THEN

    IF v_is_hire THEN
      DELETE FROM employee_personal WHERE id = v_current_row.id;
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

    ELSIF v_current_row.effective_from > p_effective_from THEN
      -- Gap-insert before the open record — find the covering closed record
      SELECT * INTO v_split_row
      FROM employee_personal
      WHERE employee_id    = p_employee_id
        AND is_active      = true
        AND effective_from <= p_effective_from
        AND effective_to   >= p_effective_from
        AND id             != v_current_row.id
      LIMIT 1;

      IF FOUND THEN
        v_new_eff_to := v_split_row.effective_to;
        UPDATE employee_personal
        SET effective_to = p_effective_from - interval '1 day',
            updated_by = auth.uid(), updated_at = NOW()
        WHERE id = v_split_row.id;

        v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_split_row.first_name,  '')), '');
        v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_split_row.middle_name, '')), '');
        v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_split_row.last_name,   '')), '');
        v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
        IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

        INSERT INTO employee_personal (
          employee_id, first_name, middle_name, last_name, name,
          nationality, marital_status, gender, dob, photo_url,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
          COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_split_row.nationality),
          COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_split_row.marital_status),
          COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_split_row.gender),
          COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_split_row.dob),
          COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_split_row.photo_url),
          p_effective_from, v_new_eff_to, true, auth.uid(), auth.uid()
        ) RETURNING id INTO v_new_id;

      ELSE
        -- Pure gap: no closed record covers p_effective_from
        DECLARE v_gap_base employee_personal%ROWTYPE; BEGIN
          SELECT * INTO v_gap_base
          FROM employee_personal
          WHERE employee_id  = p_employee_id
            AND is_active    = true
            AND effective_to < v_current_row.effective_from
          ORDER BY effective_from DESC LIMIT 1;
        END;
        v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_gap_base.first_name,  '')), '');
        v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_gap_base.middle_name, '')), '');
        v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_gap_base.last_name,   '')), '');
        v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
        IF v_computed_name = '' THEN v_computed_name := NULL; END IF;
        INSERT INTO employee_personal (
          employee_id, first_name, middle_name, last_name, name,
          nationality, marital_status, gender, dob, photo_url,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
          COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_gap_base.nationality),
          COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_gap_base.marital_status),
          COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_gap_base.gender),
          COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_gap_base.dob),
          COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_gap_base.photo_url),
          p_effective_from, v_current_row.effective_from - interval '1 day',
          true, auth.uid(), auth.uid()
        ) RETURNING id INTO v_new_id;
      END IF;

    ELSE
      -- Normal forward amendment
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
    END IF;

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

  -- ── 7. Propagation — includes dob (mig 649) ─────────────────────────────────
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
      dob = CASE
        WHEN (p_proposed_data ? 'dob') AND NULLIF(p_proposed_data->>'dob','') IS NOT NULL
        THEN (p_proposed_data->>'dob')::date ELSE dob END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 8. Sync employees.name ───────────────────────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    PERFORM set_config('prowess.allow_name_sync', 'true', true);
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
  'Mig 649: propagation now includes dob. '
  'Mig 676: prowess.trigger_context check added to access guard. '
  'Approver-triggered workflow approvals now bypass permission check correctly — '
  'auth.uid() is the approver''s ID (not NULL) in PostgREST sessions.';


-- =============================================================================
-- 3. upsert_employment_info — same prowess.trigger_context guard
--    (full rewrite from mig 675; only guard line changes)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_employment_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date    DEFAULT CURRENT_DATE,
  p_propagate      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target          employee_employment%ROWTYPE;
  v_first           employee_employment%ROWTYPE;
  v_current         employee_employment%ROWTYPE;
  v_case            text;
  v_new_id          uuid;
  v_is_system_path  boolean := false;
  v_existing_status employee_status;
  v_new_status      employee_status;
  v_designation     text;
  v_job_title       text;
  v_desig_label     text;
  v_manager_id      uuid;
  v_work_country    text;
  v_work_location   text;
  v_currency_name   text;
  v_currency_pl_id  uuid;
  v_currency_id     uuid;
  v_location_parent text;
  v_check_id        uuid;
  v_cycle_chain     text[];
  v_dept_end_date   date;
BEGIN

  -- ── 1a. Layer-A: coarse access guard ──────────────────────────────────────
  -- No session (service role) OR called from apply_profile_pending_change trigger.
  -- The trigger sets prowess.trigger_context=true (txn-local) before calling us.
  IF auth.uid() IS NULL
     OR current_setting('prowess.trigger_context', true) = 'true' THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path AND user_can('employment', 'bulk_import', NULL) THEN
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
  -- Draft/Incomplete hire bypass (mig 674)
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM employees
      WHERE id = p_employee_id
        AND status IN ('Draft', 'Incomplete', 'Pending')
    ) THEN v_is_system_path := true; END IF;
  END IF;

  IF NOT v_is_system_path THEN
    IF NOT (
      user_can('employment', 'edit',   p_employee_id)
      OR user_can('employment', 'create', p_employee_id)
      OR (p_employee_id = get_my_employee_id()
          AND (has_permission('employment.edit') OR has_permission('employment.create')))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: employment permission required.');
    END IF;
  END IF;

  -- ── 5. Case detection ──────────────────────────────────────────────────────
  SELECT * INTO v_target FROM employee_employment
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_employment
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case := 'prepend'; v_target := v_first;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_employment
    WHERE employee_id   = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_employment
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true;
    IF FOUND THEN
      v_case := 'amendment'; v_target := v_current;
    ELSE
      v_case := 'gap_fill';
      SELECT * INTO v_target FROM employee_employment
      WHERE employee_id = p_employee_id ORDER BY effective_from DESC LIMIT 1;
    END IF;
  END IF;

  -- ── 1b. Layer-B: fine-grained ─────────────────────────────────────────────
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      IF NOT (
        user_can('employment', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('employment.edit'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: employment.edit permission is required to edit an existing employment record.');
      END IF;
    ELSE
      IF NOT (
        user_can('employment', 'create', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('employment.create'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: employment.create permission is required to insert a new employment record.');
      END IF;
    END IF;
  END IF;

  -- ── 6. Manager cycle check ─────────────────────────────────────────────────
  v_manager_id := NULLIF(p_proposed_data->>'manager_id', '')::uuid;
  IF v_manager_id IS NOT NULL THEN
    IF v_manager_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'An employee cannot be their own manager.');
    END IF;
    v_check_id    := v_manager_id;
    v_cycle_chain := ARRAY[p_employee_id::text, v_manager_id::text];
    FOR _ IN 1..50 LOOP
      SELECT manager_id INTO v_check_id FROM employees WHERE id = v_check_id;
      EXIT WHEN v_check_id IS NULL;
      IF v_check_id = p_employee_id THEN
        RETURN jsonb_build_object('ok', false, 'error', 'CYCLE_DETECTED',
          'message', 'Assigning this manager would create a reporting cycle.',
          'chain', to_jsonb(v_cycle_chain));
      END IF;
      v_cycle_chain := v_cycle_chain || v_check_id::text;
    END LOOP;
  END IF;

  -- ── 6b. Clear inherited manager if inactive (mig 633) ─────────────────────
  IF v_case != 'correction' AND v_manager_id IS NULL AND v_target.manager_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM employees WHERE id = v_target.manager_id AND status = 'Inactive'
    ) THEN
      v_target.manager_id := NULL;
    END IF;
  END IF;

  -- ── 6c. Clear inherited dept if closed on effective_from (mig 634) ─────────
  IF v_case != 'correction'
     AND NULLIF(p_proposed_data->>'dept_id', '') IS NULL
     AND v_target.dept_id IS NOT NULL THEN
    SELECT end_date INTO v_dept_end_date
    FROM departments WHERE id = v_target.dept_id;
    IF v_dept_end_date IS NOT NULL
       AND v_dept_end_date != '9999-12-31'::date
       AND v_dept_end_date < p_effective_from THEN
      v_target.dept_id := NULL;
    END IF;
  END IF;

  -- ── 7. work_location parent validation ────────────────────────────────────
  IF (p_proposed_data->>'work_location') IS NOT NULL
  AND (p_proposed_data->>'work_country') IS NOT NULL THEN
    SELECT (parent_value_id)::text INTO v_location_parent
    FROM picklist_values WHERE id = (p_proposed_data->>'work_location')::uuid;
    IF v_location_parent IS DISTINCT FROM (p_proposed_data->>'work_country') THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'work_location does not belong to the selected work_country.');
    END IF;
  END IF;

  -- ── 8. Derive fields ───────────────────────────────────────────────────────
  SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;

  v_designation   := NULLIF(p_proposed_data->>'designation', '');
  v_work_country  := COALESCE(NULLIF(p_proposed_data->>'work_country', ''), v_target.work_country);
  v_work_location := NULLIF(p_proposed_data->>'work_location', '');

  SELECT (meta->>'currencyId')::uuid INTO v_currency_pl_id
  FROM picklist_values WHERE id = v_work_country::uuid;
  IF v_currency_pl_id IS NOT NULL THEN
    SELECT value INTO v_currency_name FROM picklist_values WHERE id = v_currency_pl_id;
  END IF;
  IF v_currency_name IS NOT NULL THEN
    SELECT id INTO v_currency_id FROM currencies WHERE name = v_currency_name AND active = true LIMIT 1;
  END IF;
  IF v_work_country IS NOT NULL AND v_currency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No active currency found for the selected country.');
  END IF;

  v_job_title := NULLIF(p_proposed_data->>'job_title', '');
  IF v_job_title IS NULL AND v_designation IS NOT NULL THEN
    SELECT value INTO v_desig_label FROM picklist_values WHERE id = v_designation::uuid;
    v_job_title := COALESCE(v_desig_label, v_target.job_title);
  ELSIF v_job_title IS NULL THEN
    v_job_title := v_target.job_title;
  END IF;

  v_new_status := COALESCE(
    NULLIF(p_proposed_data->>'status', '')::employee_status,
    v_target.status, v_existing_status, 'Active'::employee_status
  );

  -- ── 9. Execute by case ────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_employment SET
      designation        = v_designation,
      job_title          = v_job_title,
      dept_id            = COALESCE(NULLIF(p_proposed_data->>'dept_id', '')::uuid, v_target.dept_id),
      manager_id         = COALESCE(v_manager_id, v_target.manager_id),
      hire_date          = COALESCE(NULLIF(p_proposed_data->>'hire_date',     '')::date, v_target.hire_date),
      work_country       = v_work_country,
      work_location      = COALESCE(v_work_location, v_target.work_location),
      base_currency_id   = COALESCE(v_currency_id, v_target.base_currency_id),
      status             = v_new_status,
      probation_end_date = COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      notice_period_days = COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days),
      updated_at         = NOW(), updated_by = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
      p_effective_from, v_target.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    DECLARE v_inherited_end date := v_target.effective_to; BEGIN
      UPDATE employee_employment
      SET effective_to = p_effective_from - interval '1 day',
          updated_at = NOW(), updated_by = auth.uid()
      WHERE id = v_target.id;
      INSERT INTO employee_employment (
        employee_id, designation, job_title, dept_id, manager_id,
        hire_date, work_country, work_location, base_currency_id,
        status, probation_end_date, notice_period_days,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_designation, v_job_title,
        COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
        COALESCE(v_manager_id, v_target.manager_id),
        COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
        v_work_country, COALESCE(v_work_location, v_target.work_location),
        COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
        COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
        COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
        p_effective_from, v_inherited_end,
        v_target.is_active, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;
    END;

  ELSIF v_case IN ('amendment', 'gap_fill') THEN
    IF v_case = 'amendment' THEN
      IF v_current.effective_from >= p_effective_from THEN
        DELETE FROM employee_employment WHERE id = v_current.id;
      ELSE
        UPDATE employee_employment
        SET effective_to = p_effective_from - interval '1 day',
            is_active = false, inactive_at = NOW(),
            updated_at = NOW(), updated_by = auth.uid()
        WHERE id = v_current.id;
      END IF;
    END IF;
    INSERT INTO employee_employment (
      employee_id, designation, job_title, dept_id, manager_id,
      hire_date, work_country, work_location, base_currency_id,
      status, probation_end_date, notice_period_days,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_designation, v_job_title,
      COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, v_target.dept_id),
      COALESCE(v_manager_id, v_target.manager_id),
      COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, v_target.hire_date),
      v_work_country, COALESCE(v_work_location, v_target.work_location),
      COALESCE(v_currency_id, v_target.base_currency_id), v_new_status,
      COALESCE(NULLIF(p_proposed_data->>'probation_end_date','')::date, v_target.probation_end_date),
      COALESCE(NULLIF(p_proposed_data->>'notice_period_days','')::integer, v_target.notice_period_days, 30),
      p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 10. Propagation ───────────────────────────────────────────────────────
  IF p_propagate THEN
    UPDATE employee_employment
    SET
      designation = CASE
        WHEN (p_proposed_data ? 'designation') AND NULLIF(p_proposed_data->>'designation','') IS NOT NULL
        THEN v_designation ELSE designation END,
      job_title = CASE
        WHEN (p_proposed_data ? 'job_title') AND NULLIF(p_proposed_data->>'job_title','') IS NOT NULL
        THEN v_job_title ELSE job_title END,
      dept_id = CASE
        WHEN (p_proposed_data ? 'dept_id') AND NULLIF(p_proposed_data->>'dept_id','') IS NOT NULL
        THEN (p_proposed_data->>'dept_id')::uuid ELSE dept_id END,
      manager_id = CASE
        WHEN v_manager_id IS NOT NULL
        THEN v_manager_id ELSE manager_id END,
      work_country = CASE
        WHEN (p_proposed_data ? 'work_country') AND NULLIF(p_proposed_data->>'work_country','') IS NOT NULL
        THEN v_work_country ELSE work_country END,
      work_location = CASE
        WHEN (p_proposed_data ? 'work_location') AND NULLIF(p_proposed_data->>'work_location','') IS NOT NULL
        THEN v_work_location ELSE work_location END,
      base_currency_id = CASE
        WHEN (p_proposed_data ? 'work_country') AND NULLIF(p_proposed_data->>'work_country','') IS NOT NULL
             AND v_currency_id IS NOT NULL
        THEN v_currency_id ELSE base_currency_id END,
      notice_period_days = CASE
        WHEN (p_proposed_data ? 'notice_period_days') AND NULLIF(p_proposed_data->>'notice_period_days','') IS NOT NULL
        THEN (p_proposed_data->>'notice_period_days')::integer ELSE notice_period_days END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 11. Sync employees head record ────────────────────────────────────────
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  UPDATE employees
  SET
    designation      = v_designation,
    job_title        = v_job_title,
    dept_id          = COALESCE(NULLIF(p_proposed_data->>'dept_id','')::uuid, dept_id),
    manager_id       = COALESCE(v_manager_id, manager_id),
    hire_date        = COALESCE(NULLIF(p_proposed_data->>'hire_date','')::date, hire_date),
    work_country     = v_work_country,
    work_location    = COALESCE(v_work_location, work_location),
    base_currency_id = COALESCE(v_currency_id, base_currency_id),
    updated_at       = NOW()
  WHERE id = p_employee_id
    AND (
      p_effective_from = (
        SELECT MAX(effective_from) FROM employee_employment WHERE employee_id = p_employee_id
      )
      OR v_case = 'amendment'
    );

  RETURN jsonb_build_object('ok', true, 'id', v_new_id, 'case', v_case);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL    ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) TO authenticated;

COMMENT ON FUNCTION upsert_employment_info(uuid, jsonb, date, boolean) IS
  'Mig 674: Draft/Incomplete/Pending system-path bypass for hire wizard writes. '
  'Mig 675: auth.uid() IS NULL → v_is_system_path = true. '
  'Mig 676: prowess.trigger_context check added — mirrors personal_info fix. '
  'Approver-triggered workflow approvals now bypass permission check correctly.';
