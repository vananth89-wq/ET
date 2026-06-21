-- =============================================================================
-- Migration 300: fix dependent workflow detection
--
-- BUG (mig 290)
-- ─────────────
-- upsert_dependent and remove_dependent detect a workflow assignment by
-- querying workflow_templates directly:
--
--   SELECT id, code FROM workflow_templates
--   WHERE module_code = 'profile_dependents' AND is_active = true
--
-- This only finds a template whose OWN module_code column is 'profile_dependents'.
-- The "Hire" template (and any other template created for a different module)
-- has module_code = 'employee_hire', so the lookup always returns NULL and
-- PATH A (direct write, no approval) executes every time — even when an
-- assignment has been configured in Manage Assignments.
--
-- ROOT CAUSE
-- ──────────
-- Workflow assignments are stored in workflow_assignments, not embedded in
-- workflow_templates. The correct lookup is resolve_workflow_for_submission()
-- which reads workflow_assignments and returns the assigned template_id for a
-- (module_code, caller) pair — exactly as upsert_bank_account (mig 275) does.
--
-- FIX
-- ───
-- Replace the direct workflow_templates query with:
--
--   v_template_id := resolve_workflow_for_submission('profile_dependents', auth.uid());
--   IF v_template_id IS NOT NULL THEN
--     SELECT code INTO v_template_code
--     FROM   workflow_templates WHERE id = v_template_id;
--   END IF;
--
-- Applied to both upsert_dependent and remove_dependent.
-- =============================================================================


-- =============================================================================
-- 1. Fix upsert_dependent
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_dependent(
  p_employee_id        uuid,
  p_relationship_type  text,
  p_dependent_name     text,
  p_date_of_birth      date,
  p_gender             text,
  p_effective_from     date,
  p_dependent_code     text    DEFAULT NULL,
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
  v_template_id     uuid;
  v_template_code   text;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_prev_data       jsonb;
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
  IF p_dependent_code IS NULL THEN
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
  v_name := trim(p_dependent_name);
  IF v_name IS NULL OR length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Dependent name is required and must not be blank.');
  END IF;
  IF p_date_of_birth IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth is required.');
  END IF;
  IF p_date_of_birth > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;
  IF p_gender IS NULL OR p_gender NOT IN ('Male', 'Female') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Gender must be ''Male'' or ''Female''.');
  END IF;
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Effective from date is required.');
  END IF;
  IF p_relationship_type IS NULL OR trim(p_relationship_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Relationship type is required.');
  END IF;

  -- ── 3. Workflow detection — FIXED (mig 300) ───────────────────────────────
  -- Use resolve_workflow_for_submission() which reads workflow_assignments,
  -- not workflow_templates.module_code directly.
  v_template_id := resolve_workflow_for_submission('profile_dependents', auth.uid());
  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow assignment → direct write
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    IF p_dependent_code IS NOT NULL THEN
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

      SELECT * INTO v_current_row
      FROM   employee_dependents
      WHERE  dependent_code = p_dependent_code
        AND  employee_id    = p_employee_id
        AND  effective_to   = '9999-12-31'::date
      FOR UPDATE;

      IF FOUND THEN
        IF v_current_row.effective_from >= p_effective_from THEN
          DELETE FROM employee_dependents WHERE id = v_current_row.id;
        ELSE
          UPDATE employee_dependents
          SET    effective_to = p_effective_from - interval '1 day',
                 updated_by   = auth.uid(),
                 updated_at   = now()
          WHERE  id = v_current_row.id;
        END IF;
      END IF;
    END IF;

    INSERT INTO employee_dependents (
      dependent_code, employee_id, relationship_type, dependent_name,
      date_of_birth, gender, insurance_eligible,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_dependent_code, p_employee_id, p_relationship_type, v_name,
      p_date_of_birth, p_gender, p_insurance_eligible,
      p_effective_from, '9999-12-31'::date, true,
      auth.uid(), auth.uid()
    )
    RETURNING id INTO v_dependent_id;

    SELECT dependent_code INTO v_dependent_code
    FROM   employee_dependents WHERE id = v_dependent_id;

    FOR v_att IN SELECT * FROM jsonb_array_elements(p_attachments) LOOP
      INSERT INTO employee_dependent_attachments (
        dependent_code, employee_id, dependent_id,
        document_type, file_name, original_file_name,
        file_path, mime_type, file_size,
        uploaded_by, created_by, updated_by
      ) VALUES (
        v_dependent_code, p_employee_id, v_dependent_id,
        v_att->>'document_type', v_att->>'file_name',
        COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
        v_att->>'file_path', v_att->>'mime_type',
        (v_att->>'file_size')::bigint,
        auth.uid(), auth.uid(), auth.uid()
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
  -- PATH B: Workflow assignment found → stage in workflow_pending_changes
  -- ════════════════════════════════════════════════════════════════════════════

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
      'employee_id',       p_employee_id,
      'dependent_name',    v_name,
      'operation',         CASE WHEN p_dependent_code IS NULL THEN 'add' ELSE 'amend' END,
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
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) IS
  'Add or amend an employee dependent. '
  'Mig 289: initial creation. Mig 290: dual-path workflow staging. '
  'Mig 300: FIXED workflow detection — use resolve_workflow_for_submission() '
  '(reads workflow_assignments) instead of querying workflow_templates.module_code '
  'directly. The prior query always returned NULL because the assigned "Hire" '
  'template has module_code=employee_hire, not profile_dependents.';

REVOKE ALL     ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_dependent(uuid, text, text, date, text, date, text, boolean, boolean, jsonb) TO authenticated;


-- =============================================================================
-- 2. Fix remove_dependent
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
  v_template_id     uuid;
  v_template_code   text;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_prev_data       jsonb;
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
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
      'error', 'Cannot remove: historical rows exist that begin on or after the removal date.'
    );
  END IF;

  -- ── 5. Workflow detection — FIXED (mig 300) ───────────────────────────────
  v_template_id := resolve_workflow_for_submission('profile_dependents', auth.uid());
  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_template_id;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: No workflow → direct write
  -- ════════════════════════════════════════════════════════════════════════════
  IF v_template_id IS NULL THEN

    IF v_active_row.effective_from >= p_removal_date THEN
      UPDATE employee_dependents
      SET    is_active   = false,
             inactive_at = now(),
             inactive_by = auth.uid(),
             updated_by  = auth.uid(),
             updated_at  = now()
      WHERE  id = v_active_row.id;
    ELSE
      UPDATE employee_dependents
      SET    effective_to = p_removal_date - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_active_row.id;

      INSERT INTO employee_dependents (
        dependent_code, employee_id, relationship_type, dependent_name,
        date_of_birth, gender, insurance_eligible,
        effective_from, effective_to, is_active,
        inactive_at, inactive_by, created_by, updated_by
      ) VALUES (
        v_active_row.dependent_code, v_active_row.employee_id,
        v_active_row.relationship_type, v_active_row.dependent_name,
        v_active_row.date_of_birth, v_active_row.gender,
        v_active_row.insurance_eligible,
        p_removal_date, '9999-12-31'::date, false,
        now(), auth.uid(), auth.uid(), auth.uid()
      );
    END IF;

    RETURN jsonb_build_object('ok', true, 'workflow', false);

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: Workflow assignment found → stage removal
  -- ════════════════════════════════════════════════════════════════════════════

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
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION remove_dependent(uuid, text, date) IS
  'Soft-delete (terminate) an active dependent. '
  'Mig 289: initial creation. Mig 290: dual-path workflow staging. '
  'Mig 300: FIXED workflow detection — use resolve_workflow_for_submission() '
  'instead of querying workflow_templates.module_code directly.';

REVOKE ALL     ON FUNCTION remove_dependent(uuid, text, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION remove_dependent(uuid, text, date) TO authenticated;


-- =============================================================================
-- Verification
-- =============================================================================
DO $$
BEGIN
  ASSERT (
    SELECT COUNT(*) FROM pg_proc WHERE proname = 'upsert_dependent'
  ) >= 1, 'upsert_dependent not found after migration 300';

  ASSERT (
    SELECT COUNT(*) FROM pg_proc WHERE proname = 'remove_dependent'
  ) >= 1, 'remove_dependent not found after migration 300';

  RAISE NOTICE 'Migration 300 verified: upsert_dependent and remove_dependent updated.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 300
--
-- Root cause: mig 290 queried workflow_templates WHERE module_code = 'profile_dependents'
-- but no such template exists — the assigned "Hire" template has module_code = 'employee_hire'.
-- Workflow assignments live in workflow_assignments (linking module_code → template_id).
-- resolve_workflow_for_submission() reads workflow_assignments correctly.
-- =============================================================================
