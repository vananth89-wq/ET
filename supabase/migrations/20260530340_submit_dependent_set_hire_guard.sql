-- Migration 340: submit_dependent_set — empty-set guard + hire pipeline guard
--
-- Consolidates two fixes into one clean migration at a safe version number
-- (335 and 337 had file conflicts with parallel migrations):
--
-- 1. Empty-set guard: items=[] with no current active set → noop, no workflow task
-- 2. Hire pipeline guard: employee Draft/Incomplete/Pending → force PATH A
--    (direct write to employee_dependent_set, no profile_dependents workflow).
--    The hire workflow is the approval gate; sub-modules must not create
--    parallel workflow tasks. Without this, Save Draft in the hire wizard
--    routed dependents through PATH B, leaving them only in workflow_pending_changes
--    (not employee_dependent_set), so the portlet showed "No dependents" after save.

CREATE OR REPLACE FUNCTION submit_dependent_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item_count           INTEGER;
  v_item                 JSONB;
  v_code                 TEXT;
  v_seen_codes           TEXT[] := '{}';
  v_workflow_id          UUID;
  v_instance_id          UUID;
  v_pending_change_id    UUID;
  v_new_set_id           UUID;
  v_added_count          INTEGER := 0;
  v_existing_set_id      UUID;
  v_is_hire_pipeline     BOOLEAN := false;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_dependent_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  -- ── Hire pipeline detection ───────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  -- ── Empty-set guard ───────────────────────────────────────────────────────
  IF v_item_count = 0 THEN
    IF v_is_hire_pipeline THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
    SELECT id INTO v_existing_set_id
    FROM   employee_dependent_set
    WHERE  employee_id = p_employee_id AND is_active = true AND effective_to = '9999-12-31'::date;
    IF v_existing_set_id IS NULL THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
  END IF;

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'edit',   p_employee_id)
    OR user_can('dependents', 'create', p_employee_id)
    OR user_can('dependents', 'delete', p_employee_id)
    OR (
      v_is_hire_pipeline
      AND user_can('dependents', 'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  -- ── effective_from: snap to 1st of month ─────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  p_effective_from := date_trunc('month', p_effective_from)::date;

  -- ── Per-item validation ───────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'relationship_type' AND v_item ? 'dependent_name'
            AND v_item ? 'date_of_birth' AND v_item ? 'gender') THEN
      RAISE EXCEPTION 'submit_dependent_set: each item must include relationship_type, dependent_name, date_of_birth, gender';
    END IF;
    IF v_item->>'gender' NOT IN ('Male', 'Female') THEN
      RAISE EXCEPTION 'submit_dependent_set: gender must be Male or Female';
    END IF;
    IF (v_item->>'date_of_birth')::date > CURRENT_DATE THEN
      RAISE EXCEPTION 'submit_dependent_set: date_of_birth cannot be in the future';
    END IF;
    v_code := NULLIF(v_item->>'dependent_code', '');
    IF v_code IS NOT NULL THEN
      IF v_code = ANY(v_seen_codes) THEN
        RAISE EXCEPTION 'submit_dependent_set: duplicate dependent_code % within proposed set', v_code;
      END IF;
      v_seen_codes := array_append(v_seen_codes, v_code);
    END IF;
  END LOOP;

  -- ── Resolve workflow (hire pipeline always → PATH A) ──────────────────────
  IF v_is_hire_pipeline THEN
    v_workflow_id := NULL;
  ELSE
    v_workflow_id := resolve_workflow_for_submission('profile_dependents', auth.uid());
  END IF;

  IF v_workflow_id IS NULL THEN
    -- PATH A: direct write
    v_new_set_id := fn_apply_dependent_set_transition(
      p_employee_id, p_effective_from, p_items, auth.uid()
    );
    SELECT COUNT(*) INTO v_added_count FROM jsonb_array_elements(p_items) i
    WHERE (i->>'dependent_code') IS NULL OR (i->>'dependent_code') = '';
    RETURN jsonb_build_object(
      'ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from,
      'change_summary', format('%s added, %s items in proposed set', v_added_count, v_item_count)
    );
  ELSE
    -- PATH B: stage + wf_submit
    INSERT INTO workflow_pending_changes (module_code, record_id, status, submitted_by, proposed_data)
    VALUES (
      'profile_dependents', p_employee_id, 'pending', auth.uid(),
      jsonb_build_object('employee_id', p_employee_id, 'effective_from', p_effective_from, 'items', p_items)
    ) RETURNING id INTO v_pending_change_id;

    SELECT COUNT(*) INTO v_added_count FROM jsonb_array_elements(p_items) i
    WHERE (i->>'dependent_code') IS NULL OR (i->>'dependent_code') = '';

    PERFORM wf_submit(
      p_template_code => (SELECT code FROM workflow_templates WHERE id = v_workflow_id),
      p_module_code   => 'profile_dependents',
      p_record_id     => p_employee_id,
      p_metadata      => jsonb_build_object(
        'employee_id', p_employee_id, 'pending_change_id', v_pending_change_id,
        'change_summary', format('%s added, %s items in proposed set', v_added_count, v_item_count)
      )
    );

    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_dependents' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;

    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_change_id;

    RETURN jsonb_build_object(
      'ok', true, 'workflow', true,
      'instance_id', v_instance_id, 'pending_change_id', v_pending_change_id,
      'effective_from', p_effective_from,
      'change_summary', format('%s added, %s items in proposed set', v_added_count, v_item_count)
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) TO authenticated;

COMMENT ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) IS
  'Mig 340: empty-set guard + hire pipeline guard (force PATH A for Draft/Incomplete/Pending). '
  'Hire wizard saves directly to employee_dependent_set; hire workflow is the approval gate.';
