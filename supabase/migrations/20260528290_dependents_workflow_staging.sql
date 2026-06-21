-- =============================================================================
-- Migration 290 — Employee Dependents Workflow Staging
--
-- FUNCTIONS (updated)
-- ───────────────────
--   1. upsert_dependent          — Adds dual-path logic (PATH A: direct write,
--                                  PATH B: workflow staging) matching the bank
--                                  account pattern from Migration 275.
--
--   2. remove_dependent          — Adds dual-path logic (PATH A: direct write,
--                                  PATH B: workflow staging) for removals.
--
--   3. apply_profile_pending_change — UPDATED to add profile_dependents ELSIF
--                                  branch. Retains all existing branches.
--
-- PATH DETECTION
-- ──────────────
--   Queries workflow_templates for module_code = 'profile_dependents'.
--   NULL → PATH A (direct write, same as Mig 289).
--   Found → PATH B (insert into workflow_pending_changes, call wf_submit).
--
-- APPLY LOGIC (apply_profile_pending_change)
-- ───────────────────────────────────────────
--   operation = 'add'    → insert new dependent + attachments
--   operation = 'amend'  → close/replace existing open-ended row, insert new
--   operation = 'remove' → apply removal (matches remove_dependent RPC logic)
-- =============================================================================


-- =============================================================================
-- Part 1 — Update upsert_dependent with dual-path logic
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_dependent(
  -- Required params first (no defaults)
  p_employee_id        uuid,
  p_relationship_type  text,
  p_dependent_name     text,
  p_date_of_birth      date,
  p_gender             text,
  p_effective_from     date,
  -- Optional params with defaults
  p_dependent_code     text    DEFAULT NULL,    -- NULL = new dependent
  p_insurance_eligible boolean DEFAULT false,
  p_is_new_hire        boolean DEFAULT false,
  p_attachments        jsonb   DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dependent_id    uuid;
  v_dependent_code  text;
  v_current_row     employee_dependents%ROWTYPE;
  v_att             jsonb;
  v_name            text;
  -- Workflow staging variables
  v_template_id     uuid;
  v_template_code   text;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_prev_data       jsonb;
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Four paths:
  --   a) HR/admin: check 'create' for new dependent, 'edit' for amendment
  --   b) ESS self: same permission split
  --   c) Approver holding a pending workflow task for this employee
  --   d) Initiator whose submission was sent back for clarification
  IF p_dependent_code IS NULL THEN
    -- New dependent: require 'create' permission
    IF NOT (
      user_can('dependents', 'create', p_employee_id)
      OR (
        p_employee_id = get_my_employee_id()
        AND has_permission('dependents.create')
      )
      OR EXISTS (
        SELECT 1
        FROM   workflow_tasks wt
        JOIN   workflow_instances wi ON wi.id = wt.instance_id
        WHERE  wi.record_id   = p_employee_id
          AND  wt.assigned_to = auth.uid()
          AND  wt.status      = 'pending'
      )
      OR EXISTS (
        SELECT 1
        FROM   workflow_instances wi
        WHERE  wi.record_id    = p_employee_id
          AND  wi.submitted_by = auth.uid()
          AND  wi.status       = 'awaiting_clarification'
      )
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to add dependents for this employee.');
    END IF;
  ELSE
    -- Amendment: require 'edit' permission
    IF NOT (
      user_can('dependents', 'edit', p_employee_id)
      OR (
        p_employee_id = get_my_employee_id()
        AND has_permission('dependents.edit')
      )
      OR EXISTS (
        SELECT 1
        FROM   workflow_tasks wt
        JOIN   workflow_instances wi ON wi.id = wt.instance_id
        WHERE  wi.record_id   = p_employee_id
          AND  wt.assigned_to = auth.uid()
          AND  wt.status      = 'pending'
      )
      OR EXISTS (
        SELECT 1
        FROM   workflow_instances wi
        WHERE  wi.record_id    = p_employee_id
          AND  wi.submitted_by = auth.uid()
          AND  wi.status       = 'awaiting_clarification'
      )
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to edit dependents for this employee.');
    END IF;
  END IF;

  -- ── 2. Input validation ───────────────────────────────────────────────────
  -- Trim and validate dependent name
  v_name := trim(p_dependent_name);
  IF v_name IS NULL OR length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Dependent name is required and must not be blank.');
  END IF;

  -- Date of birth must not be in the future
  IF p_date_of_birth IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth is required.');
  END IF;
  IF p_date_of_birth > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;

  -- Gender must be Male or Female
  IF p_gender IS NULL OR p_gender NOT IN ('Male', 'Female') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Gender must be ''Male'' or ''Female''.');
  END IF;

  -- Effective from is required
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Effective from date is required.');
  END IF;

  -- Relationship type is required
  IF p_relationship_type IS NULL OR trim(p_relationship_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Relationship type is required.');
  END IF;

  -- ── 3. Check for workflow template assignment ─────────────────────────────
  SELECT id, code INTO v_template_id, v_template_code
  FROM   workflow_templates
  WHERE  module_code = 'profile_dependents'
    AND  is_active   = true
  LIMIT 1;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write (same logic as Mig 289)
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    -- Amendment path: close or replace the current open-ended row
    IF p_dependent_code IS NOT NULL THEN

      -- Pre-check: no overlap with existing closed historical rows
      IF EXISTS (
        SELECT 1
        FROM   employee_dependents
        WHERE  dependent_code = p_dependent_code
          AND  employee_id    = p_employee_id
          AND  is_active      = true
          AND  effective_to   < '9999-12-31'::date
          AND  effective_to   >= p_effective_from
      ) THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'The chosen effective date overlaps with an existing historical record.'
        );
      END IF;

      -- Fetch the current open-ended row for this dependent
      SELECT * INTO v_current_row
      FROM   employee_dependents
      WHERE  dependent_code = p_dependent_code
        AND  employee_id    = p_employee_id
        AND  effective_to   = '9999-12-31'::date
      FOR UPDATE;

      IF FOUND THEN
        -- Migration 288 pattern:
        -- If the existing row's effective_from >= p_effective_from, the new record
        -- fully replaces the old one — DELETE the old row instead.
        IF v_current_row.effective_from >= p_effective_from THEN
          DELETE FROM employee_dependents
          WHERE id = v_current_row.id;
        ELSE
          -- Standard close: set effective_to = p_effective_from - 1 day
          UPDATE employee_dependents
          SET    effective_to = p_effective_from - interval '1 day',
                 updated_by   = auth.uid(),
                 updated_at   = now()
          WHERE  id = v_current_row.id;
        END IF;
      END IF;

    END IF;

    -- Insert new row
    INSERT INTO employee_dependents (
      dependent_code,
      employee_id,
      relationship_type,
      dependent_name,
      date_of_birth,
      gender,
      insurance_eligible,
      effective_from,
      effective_to,
      is_active,
      created_by,
      updated_by
    ) VALUES (
      p_dependent_code,        -- NULL lets fn_generate_dependent_code() auto-generate
      p_employee_id,
      p_relationship_type,
      v_name,
      p_date_of_birth,
      p_gender,
      p_insurance_eligible,
      p_effective_from,
      '9999-12-31'::date,
      true,
      auth.uid(),
      auth.uid()
    )
    RETURNING id INTO v_dependent_id;

    -- Fetch the generated (or supplied) dependent_code
    SELECT dependent_code INTO v_dependent_code
    FROM   employee_dependents
    WHERE  id = v_dependent_id;

    -- Save attachments
    FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments)
    LOOP
      INSERT INTO employee_dependent_attachments (
        dependent_code,
        employee_id,
        dependent_id,
        document_type,
        file_name,
        original_file_name,
        file_path,
        mime_type,
        file_size,
        uploaded_by,
        created_by,
        updated_by
      ) VALUES (
        v_dependent_code,
        p_employee_id,
        v_dependent_id,
        v_att->>'document_type',
        v_att->>'file_name',
        v_att->>'original_file_name',
        v_att->>'file_path',
        v_att->>'mime_type',
        (v_att->>'file_size')::bigint,
        auth.uid(),
        auth.uid(),
        auth.uid()
      )
      ON CONFLICT DO NOTHING;
    END LOOP;

    RETURN jsonb_build_object(
      'ok',             true,
      'dependent_id',   v_dependent_id,
      'dependent_code', v_dependent_code,
      'workflow',       false
    );

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assigned → submit via pending change
  -- ════════════════════════════════════════════════════════════════════════════

  -- For amend: capture the current active row as prev_data snapshot
  IF p_dependent_code IS NOT NULL THEN
    SELECT row_to_json(d)::jsonb INTO v_prev_data
    FROM   employee_dependents d
    WHERE  d.dependent_code = p_dependent_code
      AND  d.effective_to   = '9999-12-31'
    LIMIT 1;
  END IF;

  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, submitted_by
  ) VALUES (
    'profile_dependents',
    -- record_id = active row id (for amend), NULL (for add)
    CASE WHEN p_dependent_code IS NOT NULL
         THEN (SELECT id FROM employee_dependents
               WHERE dependent_code = p_dependent_code
                 AND effective_to   = '9999-12-31'
               LIMIT 1)
         ELSE NULL
    END,
    CASE WHEN p_dependent_code IS NOT NULL THEN 'update' ELSE 'create' END,
    jsonb_build_object(
      'operation',          CASE WHEN p_dependent_code IS NULL THEN 'add' ELSE 'amend' END,
      'employee_id',        p_employee_id,
      'dependent_code',     p_dependent_code,
      'relationship_type',  p_relationship_type,
      'dependent_name',     v_name,
      'date_of_birth',      p_date_of_birth,
      'gender',             p_gender,
      'insurance_eligible', p_insurance_eligible,
      'effective_from',     p_effective_from,
      'attachments',        p_attachments,
      'prev_data',          v_prev_data
    ),
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'profile_dependents',
    p_record_id     => v_pending_id,
    p_metadata      => jsonb_build_object(
      'employee_id',     p_employee_id,
      'dependent_name',  v_name,
      'operation',       CASE WHEN p_dependent_code IS NULL THEN 'add' ELSE 'amend' END,
      'relationship_type', p_relationship_type
    )
  );

  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'pending_change_id', v_pending_id,
    'instance_id',       v_instance_id,
    'workflow',          true
  );

EXCEPTION WHEN OTHERS THEN
  -- Roll back any partial writes
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) IS
  'Add a new dependent (p_dependent_code = NULL) or amend an existing one '
  '(p_dependent_code = existing code). '
  'PATH A (no workflow template): direct write, same effective-dating logic as Mig 289. '
  'PATH B (workflow template found for profile_dependents): stages change in '
  'workflow_pending_changes and calls wf_submit. Does NOT write to employee_dependents directly. '
  'Returns {ok: true, dependent_id, dependent_code, workflow: false} for PATH A. '
  'Returns {ok: true, pending_change_id, instance_id, workflow: true} for PATH B. '
  'Returns {ok: false, error} on access denial or validation failure. '
  'Mig 289: initial creation. Mig 290: added dual-path workflow staging.';

REVOKE ALL     ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) TO authenticated;


-- =============================================================================
-- Part 2 — Update remove_dependent with dual-path logic
-- =============================================================================

CREATE OR REPLACE FUNCTION remove_dependent(
  p_employee_id     uuid,
  p_dependent_code  text,
  p_removal_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_row      employee_dependents%ROWTYPE;
  -- Workflow staging variables
  v_template_id     uuid;
  v_template_code   text;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_prev_data       jsonb;
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Four paths (all use 'delete' permission):
  --   a) HR/admin with dependents.delete permission scoped to employee's target group
  --   b) ESS employee removing their own dependent with dependents.delete permission
  --   c) Approver holding a pending workflow task for this employee
  --   d) Initiator whose submission was sent back for clarification
  IF NOT (
    user_can('dependents', 'delete', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('dependents.delete')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: you do not have permission to remove dependents for this employee.');
  END IF;

  -- ── 2. Validate removal date ──────────────────────────────────────────────
  IF p_removal_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Removal date is required.');
  END IF;

  -- ── 3. Find the current active open-ended row ──────────────────────────────
  SELECT * INTO v_active_row
  FROM   employee_dependents
  WHERE  dependent_code = p_dependent_code
    AND  employee_id    = p_employee_id
    AND  is_active      = true
    AND  effective_to   = '9999-12-31'::date
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No active dependent found.');
  END IF;

  -- ── 4. Check for orphaned future historical rows ──────────────────────────
  IF EXISTS (
    SELECT 1
    FROM   employee_dependents
    WHERE  dependent_code = p_dependent_code
      AND  employee_id    = p_employee_id
      AND  is_active      = true
      AND  effective_to   < '9999-12-31'::date
      AND  effective_from >= p_removal_date
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Cannot remove: historical rows exist that begin on or after the removal date. Adjust the removal date or remove future records first.'
    );
  END IF;

  -- ── 5. Check for workflow template assignment ─────────────────────────────
  SELECT id, code INTO v_template_id, v_template_code
  FROM   workflow_templates
  WHERE  module_code = 'profile_dependents'
    AND  is_active   = true
  LIMIT 1;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write (same logic as Mig 289)
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    IF v_active_row.effective_from >= p_removal_date THEN
      -- The active row's entire period falls on or after the removal date.
      -- Mark it inactive in place.
      UPDATE employee_dependents
      SET    is_active  = false,
             inactive_at = now(),
             inactive_by = auth.uid(),
             updated_by  = auth.uid(),
             updated_at  = now()
      WHERE  id = v_active_row.id;

    ELSE
      -- The active row started before the removal date.
      -- Close the current row at removal_date - 1 day.
      UPDATE employee_dependents
      SET    effective_to = p_removal_date - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_active_row.id;

      -- Insert a terminal row starting on the removal date.
      INSERT INTO employee_dependents (
        dependent_code,
        employee_id,
        relationship_type,
        dependent_name,
        date_of_birth,
        gender,
        insurance_eligible,
        effective_from,
        effective_to,
        is_active,
        inactive_at,
        inactive_by,
        created_by,
        updated_by
      ) VALUES (
        v_active_row.dependent_code,
        v_active_row.employee_id,
        v_active_row.relationship_type,
        v_active_row.dependent_name,
        v_active_row.date_of_birth,
        v_active_row.gender,
        v_active_row.insurance_eligible,
        p_removal_date,
        '9999-12-31'::date,
        false,
        now(),
        auth.uid(),
        auth.uid(),
        auth.uid()
      );

    END IF;

    RETURN jsonb_build_object('ok', true, 'workflow', false);

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assigned → submit via pending change
  -- ════════════════════════════════════════════════════════════════════════════

  -- Capture current active row as prev_data (for WorkflowReview to display)
  SELECT row_to_json(d)::jsonb INTO v_prev_data
  FROM   employee_dependents d
  WHERE  d.id = v_active_row.id;

  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, submitted_by
  ) VALUES (
    'profile_dependents',
    v_active_row.id,
    'delete',
    jsonb_build_object(
      'operation',      'remove',
      'employee_id',    p_employee_id,
      'dependent_code', p_dependent_code,
      'removal_date',   p_removal_date,
      'prev_data',      v_prev_data
    ),
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'profile_dependents',
    p_record_id     => v_pending_id,
    p_metadata      => jsonb_build_object(
      'employee_id',     p_employee_id,
      'dependent_code',  p_dependent_code,
      'dependent_name',  v_active_row.dependent_name,
      'operation',       'remove',
      'removal_date',    p_removal_date
    )
  );

  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'pending_change_id', v_pending_id,
    'instance_id',       v_instance_id,
    'workflow',          true
  );

EXCEPTION WHEN OTHERS THEN
  -- Roll back any partial writes
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION remove_dependent(uuid, text, date) IS
  'Soft-delete (terminate) an active dependent. '
  'PATH A (no workflow template): direct write — creates terminal record, same logic as Mig 289. '
  'PATH B (workflow template found for profile_dependents): stages the removal in '
  'workflow_pending_changes and calls wf_submit. Does NOT modify employee_dependents directly. '
  'Returns {ok: true, workflow: false} for PATH A. '
  'Returns {ok: true, pending_change_id, instance_id, workflow: true} for PATH B. '
  'Returns {ok: false, error} on failure. '
  'Mig 289: initial creation. Mig 290: added dual-path workflow staging.';

REVOKE ALL     ON FUNCTION remove_dependent(uuid, text, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION remove_dependent(uuid, text, date) TO authenticated;


-- =============================================================================
-- Part 3 — Update apply_profile_pending_change to handle profile_dependents
--          Retains ALL existing branches from Mig 117 and Mig 275.
-- =============================================================================

CREATE OR REPLACE FUNCTION apply_profile_pending_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id     uuid;
  v_data       jsonb;
  v_module     text;
  v_new_id     uuid;
  v_attachment jsonb;
BEGIN
  -- Only fire when status transitions INTO 'approved'
  IF NEW.status <> 'approved' OR OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  v_module := NEW.module_code;
  v_data   := NEW.proposed_data;

  -- Only handle profile_* modules
  IF v_module NOT LIKE 'profile_%' THEN
    RETURN NEW;
  END IF;

  -- Resolve the employee's UUID via the submitter's profile
  SELECT p.employee_id INTO v_emp_id
  FROM   profiles p
  WHERE  p.id = NEW.submitted_by;

  IF v_emp_id IS NULL THEN
    RAISE WARNING
      'apply_profile_pending_change: cannot resolve employee_id for submitted_by=%, module=%, pending_change=%',
      NEW.submitted_by, v_module, NEW.id;
    RETURN NEW;
  END IF;

  -- ── profile_personal → employee_personal ────────────────────────────────
  IF v_module = 'profile_personal' THEN
    INSERT INTO employee_personal (
      employee_id, nationality, marital_status, gender, dob
    ) VALUES (
      v_emp_id,
      v_data->>'nationality',
      v_data->>'marital_status',
      v_data->>'gender',
      NULLIF(v_data->>'dob', '')::date
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      nationality    = EXCLUDED.nationality,
      marital_status = EXCLUDED.marital_status,
      gender         = EXCLUDED.gender,
      dob            = EXCLUDED.dob;

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
        line1    = v_data->>'line1',
        line2    = v_data->>'line2',
        landmark = v_data->>'landmark',
        city     = v_data->>'city',
        district = v_data->>'district',
        state    = v_data->>'state',
        pin      = v_data->>'pin',
        country  = v_data->>'country'
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO employee_addresses (
        employee_id, line1, line2, landmark, city, district, state, pin, country
      ) VALUES (
        v_emp_id,
        v_data->>'line1',    v_data->>'line2',    v_data->>'landmark',
        v_data->>'city',     v_data->>'district', v_data->>'state',
        v_data->>'pin',      v_data->>'country'
      );
    END IF;

  -- ── profile_passport → passports ────────────────────────────────────────
  ELSIF v_module = 'profile_passport' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE passports
      SET
        country         = v_data->>'country',
        passport_number = v_data->>'passport_number',
        issue_date      = NULLIF(v_data->>'issue_date',  '')::date,
        expiry_date     = NULLIF(v_data->>'expiry_date', '')::date
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO passports (
        employee_id, country, passport_number, issue_date, expiry_date
      ) VALUES (
        v_emp_id,
        v_data->>'country',
        v_data->>'passport_number',
        NULLIF(v_data->>'issue_date',  '')::date,
        NULLIF(v_data->>'expiry_date', '')::date
      );
    END IF;

  -- ── profile_emergency_contact → emergency_contacts ──────────────────────
  ELSIF v_module = 'profile_emergency_contact' THEN
    IF NEW.record_id IS NOT NULL THEN
      UPDATE emergency_contacts
      SET
        name         = v_data->>'name',
        relationship = v_data->>'relationship',
        phone        = v_data->>'phone',
        alt_phone    = v_data->>'alt_phone',
        email        = v_data->>'email'
      WHERE id = NEW.record_id;
    ELSE
      INSERT INTO emergency_contacts (
        employee_id, name, relationship, phone, alt_phone, email
      ) VALUES (
        v_emp_id,
        v_data->>'name',      v_data->>'relationship',
        v_data->>'phone',     v_data->>'alt_phone',
        v_data->>'email'
      );
    END IF;

  -- ── profile_bank → employee_bank_accounts ───────────────────────────────
  --    proposed_data shape:
  --      { employee_id, bank_account_group_id, country_code, currency_code,
  --        bank_name, branch_name, branch_code, account_holder_name,
  --        account_number, ifsc_code, iban, swift_bic, is_primary,
  --        effective_from, prev_active_id (nullable), attachments[] }
  ELSIF v_module = 'profile_bank' THEN

    -- Close the previous active version if amending
    IF (v_data->>'prev_active_id') IS NOT NULL THEN
      UPDATE employee_bank_accounts
      SET    effective_to = (v_data->>'effective_from')::date - interval '1 day',
             updated_at   = now(),
             updated_by   = NEW.submitted_by
      WHERE  id = (v_data->>'prev_active_id')::uuid;
    END IF;

    -- Insert the new bank account version
    INSERT INTO employee_bank_accounts (
      employee_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code, account_holder_name,
      account_number, ifsc_code, iban, swift_bic,
      is_primary, effective_from, effective_to,
      created_by, updated_by
    ) VALUES (
      (v_data->>'employee_id')::uuid,
      (v_data->>'bank_account_group_id')::uuid,
      v_data->>'country_code',
      v_data->>'currency_code',
      v_data->>'bank_name',
      v_data->>'branch_name',
      v_data->>'branch_code',
      v_data->>'account_holder_name',
      v_data->>'account_number',
      v_data->>'ifsc_code',
      v_data->>'iban',
      v_data->>'swift_bic',
      COALESCE((v_data->>'is_primary')::boolean, false),
      (v_data->>'effective_from')::date,
      '9999-12-31'::date,
      NEW.submitted_by,
      NEW.submitted_by
    )
    RETURNING id INTO v_new_id;

    -- Insert attachments from proposed_data
    IF v_data->'attachments' IS NOT NULL THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_data->'attachments') LOOP
        INSERT INTO employee_bank_attachments (
          bank_account_id, employee_id, file_name, file_type, file_size,
          storage_path, uploaded_by
        ) VALUES (
          v_new_id,
          (v_data->>'employee_id')::uuid,
          v_attachment->>'file_name',
          v_attachment->>'file_type',
          (v_attachment->>'file_size')::integer,
          v_attachment->>'storage_path',
          NEW.submitted_by
        );
      END LOOP;
    END IF;

  -- ── profile_dependents → employee_dependents ────────────────────────────
  --    proposed_data shape:
  --      { operation ('add'|'amend'|'remove'), employee_id, dependent_code,
  --        relationship_type, dependent_name, date_of_birth, gender,
  --        insurance_eligible, effective_from (add/amend), removal_date (remove),
  --        attachments[], prev_data (jsonb snapshot of old row, nullable) }
  ELSIF v_module = 'profile_dependents' THEN
    DECLARE
      v_op          text     := v_data->>'operation';
      v_dep_code    text     := v_data->>'dependent_code';
      v_active_dep  employee_dependents%ROWTYPE;
      v_new_dep_id  uuid;
      v_att_dep     jsonb;
    BEGIN
      IF v_op IN ('add', 'amend') THEN
        -- For amend: close or delete the current open-ended row (Mig 288 pattern)
        IF v_op = 'amend' AND v_dep_code IS NOT NULL THEN
          SELECT * INTO v_active_dep
          FROM employee_dependents
          WHERE dependent_code = v_dep_code AND effective_to = '9999-12-31';
          IF FOUND THEN
            IF v_active_dep.effective_from >= (v_data->>'effective_from')::date THEN
              DELETE FROM employee_dependents WHERE id = v_active_dep.id;
            ELSE
              UPDATE employee_dependents
              SET effective_to = (v_data->>'effective_from')::date - interval '1 day',
                  updated_at   = now(),
                  updated_by   = NEW.submitted_by
              WHERE id = v_active_dep.id;
            END IF;
          END IF;
        END IF;

        -- Insert new dependent row
        INSERT INTO employee_dependents (
          dependent_code, employee_id, relationship_type, dependent_name,
          date_of_birth, gender, insurance_eligible,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          v_dep_code,  -- NULL for add → trigger auto-generates
          v_emp_id,    -- resolved from submitted_by above
          v_data->>'relationship_type',
          v_data->>'dependent_name',
          (v_data->>'date_of_birth')::date,
          v_data->>'gender',
          COALESCE((v_data->>'insurance_eligible')::boolean, false),
          (v_data->>'effective_from')::date,
          '9999-12-31'::date,
          true,
          NEW.submitted_by,
          NEW.submitted_by
        )
        RETURNING id INTO v_new_dep_id;

        -- Fetch generated dependent_code (when it was NULL / auto-generated)
        IF v_dep_code IS NULL THEN
          SELECT dependent_code INTO v_dep_code
          FROM employee_dependents WHERE id = v_new_dep_id;
        END IF;

        -- Insert attachments
        IF v_data->'attachments' IS NOT NULL THEN
          FOR v_att_dep IN SELECT * FROM jsonb_array_elements(v_data->'attachments') LOOP
            INSERT INTO employee_dependent_attachments (
              dependent_code, employee_id, dependent_id,
              document_type, file_name, original_file_name,
              file_path, mime_type, file_size,
              uploaded_by, created_by, updated_by
            ) VALUES (
              v_dep_code,
              v_emp_id,
              v_new_dep_id,
              v_att_dep->>'document_type',
              v_att_dep->>'file_name',
              COALESCE(v_att_dep->>'original_file_name', v_att_dep->>'file_name'),
              v_att_dep->>'file_path',
              v_att_dep->>'mime_type',
              (v_att_dep->>'file_size')::bigint,
              NEW.submitted_by, NEW.submitted_by, NEW.submitted_by
            );
          END LOOP;
        END IF;

      ELSIF v_op = 'remove' THEN
        -- Apply the removal pattern from remove_dependent RPC
        SELECT * INTO v_active_dep
        FROM employee_dependents
        WHERE dependent_code = v_dep_code
          AND effective_to   = '9999-12-31'
          AND is_active      = true;

        IF FOUND THEN
          IF v_active_dep.effective_from >= (v_data->>'removal_date')::date THEN
            UPDATE employee_dependents
            SET is_active  = false,
                inactive_at = now(),
                inactive_by = NEW.submitted_by,
                updated_by  = NEW.submitted_by,
                updated_at  = now()
            WHERE id = v_active_dep.id;
          ELSE
            UPDATE employee_dependents
            SET effective_to = (v_data->>'removal_date')::date - interval '1 day',
                updated_by   = NEW.submitted_by,
                updated_at   = now()
            WHERE id = v_active_dep.id;

            INSERT INTO employee_dependents (
              dependent_code, employee_id, relationship_type, dependent_name,
              date_of_birth, gender, insurance_eligible,
              effective_from, effective_to, is_active,
              inactive_at, inactive_by, created_by, updated_by
            ) VALUES (
              v_active_dep.dependent_code, v_active_dep.employee_id,
              v_active_dep.relationship_type, v_active_dep.dependent_name,
              v_active_dep.date_of_birth, v_active_dep.gender,
              v_active_dep.insurance_eligible,
              (v_data->>'removal_date')::date, '9999-12-31'::date, false,
              now(), NEW.submitted_by, NEW.submitted_by, NEW.submitted_by
            );
          END IF;
        END IF;
      END IF;
    END;

  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_profile_pending_change() IS
  'AFTER UPDATE trigger on workflow_pending_changes. '
  'Fires when status transitions to ''approved'' for any profile_* module. '
  'Applies proposed_data to the correct satellite table. '
  'Modules: profile_personal → employee_personal, profile_contact → employee_contact, '
  'profile_address → employee_addresses, profile_passport → passports, '
  'profile_emergency_contact → emergency_contacts, profile_bank → employee_bank_accounts, '
  'profile_dependents → employee_dependents. '
  'Mig 117: initial creation. Mig 275: added profile_bank → employee_bank_accounts. '
  'Mig 290: added profile_dependents → employee_dependents.';


-- =============================================================================
-- Part 4 — Verification SELECTs
-- =============================================================================

SELECT proname, prosecdef, pronargs
FROM   pg_proc
WHERE  proname IN (
  'upsert_dependent',
  'remove_dependent',
  'apply_profile_pending_change'
)
ORDER BY proname;

-- =============================================================================
-- END OF MIGRATION 290
-- =============================================================================
