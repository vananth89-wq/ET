-- =============================================================================
-- Migration 397 — Education Module: Workflow Branches
--
-- TWO CHANGES (full function recreations — only the CASE/ELSIF chains gain
-- the new profile_education branch; all other branches unchanged from mig 364):
--
-- 1. submit_change_request — add profile_education snapshot branch
--    For an edit (p_record_id IS NOT NULL): snapshots the current row.
--    For a new record: current_data = NULL (nothing to diff against).
--
-- 2. apply_profile_pending_change — add profile_education apply branch
--    On approval: calls upsert_education (or remove_education for
--    _operation='remove' payloads). Registers profile_education in
--    the handled module list.
--
-- 3. Register profile_education in module_codes
--
-- Design spec: docs/education-design.md §5
-- Template:    mig 364 (profile_job_relationships workflow branches)
-- Predecessor: mig 396 (RPCs — upsert_education must exist before apply branch)
-- Next:        mig 398 (bulk template + export)
-- =============================================================================


-- =============================================================================
-- 1. submit_change_request — add profile_education snapshot branch
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

  -- ── Resolve caller's employee_id ────────────────────────────────────────────
  SELECT p.employee_id
  INTO   v_emp_id
  FROM   profiles p
  WHERE  p.id = auth.uid();

  -- ── Resolve workflow template ───────────────────────────────────────────────
  SELECT t.id, t.code
  INTO   v_template_id, v_template_code
  FROM   workflow_templates t
  WHERE  t.module_code = p_module_code
    AND  t.is_active   = true
  ORDER  BY t.created_at DESC
  LIMIT  1;

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', format('No active workflow template found for module_code=%L', p_module_code)
    );
  END IF;

  -- ── Snapshot current data for diff display ──────────────────────────────────
  IF v_emp_id IS NOT NULL AND p_action = 'update' THEN

    CASE p_module_code

      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*)
        INTO   v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id  = v_emp_id
          AND  ep.effective_to = '9999-12-31'::date
          AND  ep.is_active    = true;

      WHEN 'profile_employment' THEN
        SELECT to_jsonb(ee.*)
        INTO   v_current_row
        FROM   employee_employment ee
        WHERE  ee.employee_id  = v_emp_id
          AND  ee.effective_to = '9999-12-31'::date
          AND  ee.is_active    = true;

      WHEN 'profile_job_relationships' THEN
        SELECT jsonb_build_object(
          'set_id',         s.id,
          'effective_from', s.effective_from,
          'items',          COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'relationship_code',    i.relationship_code,
              'manager_employee_id',  i.manager_employee_id
            ))
            FROM employee_job_relationship_item i
            WHERE i.set_id = s.id
          ), '[]'::jsonb)
        )
        INTO v_current_row
        FROM employee_job_relationship_set s
        WHERE s.employee_id  = v_emp_id
          AND s.is_active    = true
          AND s.effective_to = '9999-12-31'::date;

      -- ── NEW: profile_education snapshot ─────────────────────────────────────
      WHEN 'profile_education' THEN
        -- For an edit, snapshot the current row; for a new record, nothing to snap
        IF p_record_id IS NOT NULL THEN
          SELECT to_jsonb(ee.*)
          INTO   v_current_row
          FROM   employee_education ee
          WHERE  ee.id        = p_record_id
            AND  ee.is_active = true;
        END IF;
        -- v_current_row stays NULL for new-record submissions

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
  'Resolves the active workflow template for the module via module_code lookup. '
  'Snapshots the current satellite row into current_data (filtered to proposed_data keys). '
  'Mig 354: added profile_employment snapshot branch. '
  'Mig 364: added profile_job_relationships snapshot branch. '
  'Mig 397: added profile_education snapshot branch (current row by p_record_id; NULL for new).';

REVOKE ALL     ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) TO authenticated;


-- =============================================================================
-- 2. apply_profile_pending_change — add profile_education branch
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
  -- JR-specific
  v_old_set_id uuid;
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

  -- ── profile_personal → upsert_personal_info ─────────────────────────────────
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

  -- ── profile_employment → upsert_employment_info ──────────────────────────────
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

  -- ── profile_job_relationships → upsert_job_relationship_set ─────────────────
  ELSIF v_module = 'profile_job_relationships' THEN

    v_eff_from := COALESCE(
      NULLIF(v_data->>'effective_from', '')::date,
      CURRENT_DATE
    );

    SELECT id INTO v_old_set_id
    FROM   employee_job_relationship_set
    WHERE  employee_id  = v_emp_id
      AND  is_active    = true
      AND  effective_to = '9999-12-31'::date;

    v_result := upsert_job_relationship_set(
      v_emp_id,
      v_eff_from,
      COALESCE(v_data->'items', '[]'::jsonb)
    );

    IF NOT (v_result->>'ok')::boolean THEN
      RAISE WARNING
        'apply_profile_pending_change: upsert_job_relationship_set failed for employee=%, error=%',
        v_emp_id, v_result->>'error';
    ELSE
      BEGIN
        PERFORM fn_queue_job_relationship_notifications(
          v_emp_id,
          (v_result->>'set_id')::uuid,
          v_old_set_id,
          NEW.submitted_by
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
          'apply_profile_pending_change: notification queuing failed for employee=%, error=%',
          v_emp_id, SQLERRM;
      END;
    END IF;

  -- ── profile_education → upsert_education / remove_education ─────────────────
  ELSIF v_module = 'profile_education' THEN

    -- Removal payload: { _operation: 'remove', education_id: <uuid> }
    IF v_data->>'_operation' = 'remove' THEN
      v_result := remove_education(
        v_emp_id,
        (v_data->>'education_id')::uuid
      );
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING
          'apply_profile_pending_change: remove_education failed for employee=%, error=%',
          v_emp_id, v_result->>'error';
      END IF;
    ELSE
      -- Add or edit — pass record_id (NULL = new record)
      v_result := upsert_education(
        v_emp_id,
        v_data,
        NEW.record_id    -- NULL for new, UUID for edit
      );
      IF NOT (v_result->>'ok')::boolean THEN
        RAISE WARNING
          'apply_profile_pending_change: upsert_education failed for employee=%, error=%',
          v_emp_id, v_result->>'error';
      END IF;
    END IF;

  -- ── profile_contact → employee_contact ──────────────────────────────────────
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

  -- ── profile_address → employee_addresses ────────────────────────────────────
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

  -- ── profile_passport → passports ────────────────────────────────────────────
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

  -- ── profile_identification → identity_records ────────────────────────────────
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

  -- ── profile_emergency_contact → emergency_contacts ───────────────────────────
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

  -- ── profile_bank / profile_dependents — handled by their own apply branches ──
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
  'Trigger on workflow_pending_changes: fires when status → approved. '
  'Routes to the appropriate upsert RPC based on module_code. '
  'Modules handled: profile_personal, profile_employment, profile_job_relationships, '
  'profile_education, profile_contact, profile_address, profile_passport, '
  'profile_identification, profile_emergency_contact, profile_bank, profile_dependents. '
  'Mig 364: added profile_job_relationships branch. '
  'Mig 397: added profile_education branch (upsert_education or remove_education).';


-- =============================================================================
-- 3. Register profile_education in module_codes
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'module_codes'
  ) THEN
    INSERT INTO module_codes (code, label)
    VALUES ('profile_education', 'Education')
    ON CONFLICT (code) DO NOTHING;
  END IF;
END;
$$;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT proname,
       prosrc LIKE '%profile_education%' AS has_education_branch
FROM   pg_proc
WHERE  proname IN ('submit_change_request', 'apply_profile_pending_change')
ORDER  BY proname;

-- =============================================================================
-- END OF MIGRATION 397
-- =============================================================================
