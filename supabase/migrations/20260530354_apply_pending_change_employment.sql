-- =============================================================================
-- Migration 354 — Wire profile_employment into workflow apply path
-- =============================================================================
--
-- TWO CHANGES:
--
-- 1. submit_change_request — add profile_employment snapshot branch
--    Snapshots the current open-ended employee_employment slice into
--    current_data so approvers see before/after diffs.
--
-- 2. apply_profile_pending_change — add profile_employment apply branch
--    When a profile_employment request is approved, calls
--    upsert_employment_info() which handles the full effective-dated
--    close-then-insert and employees mirror sync.
--
-- Design spec: §8 — docs/employment-effective-dating-design.md
-- Template:    mig 319 (profile_personal apply branch)
-- =============================================================================


-- =============================================================================
-- 1. submit_change_request — add profile_employment snapshot
-- =============================================================================
-- Full function recreated (matches pattern of mig 319, 330, 321, etc.).
-- Only the CASE block gains the 'profile_employment' branch; everything else
-- is unchanged from mig 319 (last edit of this function).
-- =============================================================================

CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code   text,
  p_record_id     uuid    DEFAULT NULL,
  p_proposed_data jsonb   DEFAULT '{}',
  p_action        text    DEFAULT 'update',
  p_comment       text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id        uuid;
  v_template_id   uuid;
  v_template_code text;
  v_pending_id    uuid;
  v_instance_id   uuid;
  v_current_row   jsonb   := NULL;
  v_current_data  jsonb   := NULL;
  v_key           text;
BEGIN
  -- ── Basic validation ────────────────────────────────────────────────────────
  IF p_module_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code is required.');
  END IF;

  IF p_module_code = 'expense_reports' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Use submit_expense() for expense_reports, not submit_change_request().'
    );
  END IF;

  IF p_action NOT IN ('create', 'update', 'delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'action must be create, update, or delete.');
  END IF;

  -- ── Must be linked to an employee ───────────────────────────────────────────
  v_emp_id := get_my_employee_id();

  -- ── Resolve workflow ────────────────────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid());

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'No active workflow assignment found for module "%s". '
        'Ask your administrator to configure one in Workflow → Assignments.',
        p_module_code
      )
    );
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_template_id;

  -- ── Snapshot current values ─────────────────────────────────────────────────
  IF v_emp_id IS NOT NULL AND p_action = 'update' THEN

    CASE p_module_code

      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*)
        INTO   v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id  = v_emp_id
          AND  ep.effective_to = '9999-12-31'::date
          AND  ep.is_active    = true;

      -- ── NEW: profile_employment snapshot ────────────────────────────────
      WHEN 'profile_employment' THEN
        SELECT to_jsonb(ee.*)
        INTO   v_current_row
        FROM   employee_employment ee
        WHERE  ee.employee_id  = v_emp_id
          AND  ee.effective_to = '9999-12-31'::date
          AND  ee.is_active    = true;

      WHEN 'profile_contact' THEN
        SELECT to_jsonb(ec.*)
        INTO   v_current_row
        FROM   employee_contact ec
        WHERE  ec.employee_id = v_emp_id;

      WHEN 'profile_address' THEN
        SELECT to_jsonb(ea.*)
        INTO   v_current_row
        FROM   employee_addresses ea
        WHERE  ea.employee_id = v_emp_id;

      WHEN 'profile_passport' THEN
        SELECT to_jsonb(pp.*)
        INTO   v_current_row
        FROM   passports pp
        WHERE  pp.employee_id = v_emp_id;

      WHEN 'profile_identification' THEN
        SELECT to_jsonb(ir.*)
        INTO   v_current_row
        FROM   identity_records ir
        WHERE  ir.employee_id = v_emp_id;

      WHEN 'profile_emergency_contact' THEN
        SELECT to_jsonb(emg.*)
        INTO   v_current_row
        FROM   emergency_contacts emg
        WHERE  emg.employee_id = v_emp_id
        ORDER  BY emg.created_at
        LIMIT  1;

      ELSE
        NULL;

    END CASE;

    -- Filter snapshot to only keys present in proposed_data
    IF v_current_row IS NOT NULL THEN
      v_current_data := '{}'::jsonb;
      FOR v_key IN SELECT jsonb_object_keys(p_proposed_data) LOOP
        IF v_current_row ? v_key THEN
          v_current_data := v_current_data || jsonb_build_object(v_key, v_current_row->v_key);
        END IF;
      END LOOP;
    END IF;

  END IF;

  -- ── Create the pending change record ────────────────────────────────────────
  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, current_data, submitted_by
  ) VALUES (
    p_module_code,
    p_record_id,
    p_action,
    COALESCE(p_proposed_data, '{}'),
    v_current_data,
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  -- ── Submit to workflow engine ────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => p_module_code,
    p_record_id     => v_pending_id,
    p_metadata      => COALESCE(p_proposed_data, '{}'),
    p_comment       => NULLIF(trim(COALESCE(p_comment, '')), '')
  );

  -- ── Link instance back to pending change ─────────────────────────────────────
  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'pending_id',  v_pending_id,
    'instance_id', v_instance_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) IS
  'Stages a profile field change for workflow approval. '
  'Resolves the active workflow template for the module via resolve_workflow_for_submission(). '
  'Snapshots the current satellite row into current_data (filtered to proposed_data keys). '
  'Mig 354: added profile_employment snapshot branch (current open-ended ee slice).';

REVOKE ALL     ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) TO authenticated;


-- =============================================================================
-- 2. apply_profile_pending_change — add profile_employment branch
-- =============================================================================
-- Full trigger function recreated. Only the ELSE branch gains profile_employment;
-- all existing branches are unchanged from mig 319 (last authoritative version).
-- =============================================================================

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
BEGIN
  -- Only fire on status → 'approved'
  IF NEW.status != 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- Resolve employee_id from the submitter's profile
  SELECT p.employee_id
  INTO   v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
  END IF;

  -- ── profile_personal → upsert_personal_info ──────────────────────────────
  IF v_module = 'profile_personal' THEN

    v_eff_from := COALESCE(
      NULLIF(v_data->>'effective_from', '')::date,
      CURRENT_DATE
    );

    v_result := upsert_personal_info(v_emp_id, v_data, v_eff_from);

    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING
        'apply_profile_pending_change: upsert_personal_info failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    END IF;

  -- ── profile_employment → upsert_employment_info ──────────────────────────
  ELSIF v_module = 'profile_employment' THEN

    v_eff_from := COALESCE(
      NULLIF(v_data->>'effective_from', '')::date,
      CURRENT_DATE
    );

    v_result := upsert_employment_info(v_emp_id, v_data, v_eff_from);

    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING
        'apply_profile_pending_change: upsert_employment_info failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    END IF;

  -- ── profile_contact → employee_contact ──────────────────────────────────
  ELSIF v_module = 'profile_contact' THEN
    INSERT INTO employee_contact (
      employee_id, country_code, mobile, personal_email
    ) VALUES (
      v_emp_id,
      v_data->>'country_code',
      v_data->>'mobile',
      v_data->>'personal_email'
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      country_code   = EXCLUDED.country_code,
      mobile         = EXCLUDED.mobile,
      personal_email = EXCLUDED.personal_email;

  -- ── profile_address → employee_addresses ────────────────────────────────
  ELSIF v_module = 'profile_address' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE employee_addresses
      SET
        address_type = COALESCE(v_data->>'address_type', address_type),
        line1        = COALESCE(v_data->>'line1',        line1),
        line2        = COALESCE(v_data->>'line2',        line2),
        city         = COALESCE(v_data->>'city',         city),
        state        = COALESCE(v_data->>'state',        state),
        country      = COALESCE(v_data->>'country',      country),
        pincode      = COALESCE(v_data->>'pincode',      pincode),
        updated_at   = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO employee_addresses (
        employee_id, address_type, line1, line2, city, state, country, pincode
      ) VALUES (
        v_emp_id,
        v_data->>'address_type',
        v_data->>'line1',
        v_data->>'line2',
        v_data->>'city',
        v_data->>'state',
        v_data->>'country',
        v_data->>'pincode'
      );
    END IF;

  -- ── profile_passport → passports ────────────────────────────────────────
  ELSIF v_module = 'profile_passport' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE passports
      SET
        passport_number  = COALESCE(v_data->>'passport_number',  passport_number),
        country_of_issue = COALESCE(v_data->>'country_of_issue', country_of_issue),
        issue_date       = COALESCE(NULLIF(v_data->>'issue_date','')::date,  issue_date),
        expiry_date      = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at       = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO passports (
        employee_id, passport_number, country_of_issue, issue_date, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'passport_number',
        v_data->>'country_of_issue',
        NULLIF(v_data->>'issue_date',  '')::date,
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_identification → identity_records ────────────────────────────
  ELSIF v_module = 'profile_identification' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE identity_records
      SET
        id_type     = COALESCE(v_data->>'id_type',     id_type),
        id_number   = COALESCE(v_data->>'id_number',   id_number),
        expiry_date = COALESCE(NULLIF(v_data->>'expiry_date','')::date, expiry_date),
        updated_at  = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO identity_records (
        employee_id, id_type, id_number, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'id_type',
        v_data->>'id_number',
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_emergency_contact → emergency_contacts ───────────────────────
  ELSIF v_module = 'profile_emergency_contact' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE emergency_contacts
      SET
        name         = COALESCE(v_data->>'name',         name),
        relationship = COALESCE(v_data->>'relationship', relationship),
        phone        = COALESCE(v_data->>'phone',        phone),
        email        = COALESCE(v_data->>'email',        email),
        updated_at   = now()
      WHERE id = NEW.record_id
        AND employee_id = v_emp_id;
    ELSE
      INSERT INTO emergency_contacts (
        employee_id, name, relationship, phone, email
      ) VALUES (
        v_emp_id,
        v_data->>'name',
        v_data->>'relationship',
        v_data->>'phone',
        v_data->>'email'
      );
    END IF;

  -- ── profile_bank / profile_dependents — handled by their own apply branches
  ELSIF v_module IN ('profile_bank', 'profile_dependents') THEN
    NULL;

  ELSE
    RAISE NOTICE
      'apply_profile_pending_change: unhandled module_code=% for pending_change=%',
      v_module, NEW.id;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING
    'apply_profile_pending_change: unhandled exception for pending_change=%, error=%',
    NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'AFTER UPDATE trigger on workflow_pending_changes. Fires when status → ''approved''. '
  'Routes proposed_data to the correct satellite table based on module_code. '
  'Mig 354: added profile_employment branch → calls upsert_employment_info(). '
  'effective_from read from proposed_data; defaults to CURRENT_DATE when absent.';

DROP TRIGGER IF EXISTS trg_apply_profile_pending_change ON workflow_pending_changes;

CREATE TRIGGER trg_apply_profile_pending_change
  AFTER UPDATE OF status ON workflow_pending_changes
  FOR EACH ROW
  EXECUTE FUNCTION apply_profile_pending_change();
