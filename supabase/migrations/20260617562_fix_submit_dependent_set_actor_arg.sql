-- =============================================================================
-- Migration 562 — Fix submit_dependent_set: pass v_actor to fn_apply_dependent_set_transition
--
-- BUG
-- ───
-- Mig 509 (portlet_rpcs_subject_employee) rewrote submit_dependent_set but
-- called fn_apply_dependent_set_transition with only 3 args:
--
--   fn_apply_dependent_set_transition(p_employee_id, p_effective_from, p_items)
--
-- The function signature has required 4 args since mig 322:
--
--   fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID)   ← 4th = p_actor
--
-- This causes the error on Submit for Approval in the hire wizard:
--   "function fn_apply_dependent_set_transition(uuid, date, jsonb) does not exist"
--
-- FIX
-- ───
-- Replace submit_dependent_set with corrected body — one-line change on the
-- direct-write path: add v_actor as the 4th argument.
-- =============================================================================

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
  v_actor            UUID := auth.uid();
  v_item_count       INTEGER;
  v_item             JSONB;
  v_added_count      INTEGER := 0;
  v_removed_count    INTEGER := 0;
  v_template_id      UUID;
  v_template_code    TEXT;
  v_pending_id       UUID;
  v_instance_id      UUID;
  v_new_set_id       UUID;
  v_change_summary   TEXT;
  v_code             TEXT;
  v_seen_codes       TEXT[] := '{}';
  v_is_hire_pipeline BOOLEAN := false;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_dependent_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  SELECT EXISTS (
    SELECT 1 FROM employees WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  IF v_item_count = 0 THEN
    IF v_is_hire_pipeline THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM employee_dependent_set
      WHERE employee_id = p_employee_id AND is_active = true AND effective_to = '9999-12-31'::date
    ) THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
  END IF;

  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'edit',   p_employee_id)
    OR user_can('dependents', 'create', p_employee_id)
    OR user_can('dependents', 'delete', p_employee_id)
    OR (v_is_hire_pipeline AND user_can('dependents', 'edit', NULL) AND user_can('hire_employee', 'edit', NULL))
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'relationship_type' AND v_item ? 'dependent_name'
            AND v_item ? 'date_of_birth'  AND v_item ? 'gender') THEN
      RAISE EXCEPTION 'submit_dependent_set: each item must include relationship_type, dependent_name, date_of_birth, gender';
    END IF;
    IF (v_item->>'gender') NOT IN ('Male', 'Female') THEN
      RAISE EXCEPTION 'submit_dependent_set: gender must be Male or Female';
    END IF;
    IF (v_item->>'date_of_birth')::date > CURRENT_DATE THEN
      RAISE EXCEPTION 'submit_dependent_set: date_of_birth cannot be in the future';
    END IF;
    v_code := v_item->>'dependent_code';
    IF v_code IS NOT NULL THEN
      IF v_code = ANY(v_seen_codes) THEN
        RAISE EXCEPTION 'submit_dependent_set: duplicate dependent_code % within proposed set', v_code;
      END IF;
      v_seen_codes := array_append(v_seen_codes, v_code);
    END IF;
    IF (v_item->>'operation') = 'add' OR v_code IS NULL THEN
      v_added_count := v_added_count + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_removed_count
  FROM employee_dependent_item di
  JOIN employee_dependent_set  ds ON ds.id = di.set_id
  WHERE ds.employee_id = p_employee_id AND ds.is_active = true AND ds.effective_to = '9999-12-31'::date
    AND di.dependent_code <> ALL(
      SELECT COALESCE(j->>'dependent_code', '') FROM jsonb_array_elements(p_items) j
      WHERE j->>'dependent_code' IS NOT NULL
    );

  v_change_summary := format('%s added, %s removed, %s dependents in proposed set',
    v_added_count, v_removed_count, v_item_count);

  IF p_effective_from IS NULL THEN
    p_effective_from := CURRENT_DATE;
  END IF;

  IF v_is_hire_pipeline THEN
    v_template_id := NULL;
  ELSE
    v_template_id := resolve_workflow_for_submission('profile_dependents', v_actor);
  END IF;

  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;
    INSERT INTO workflow_pending_changes (module_code, record_id, status, submitted_by, proposed_data, created_at)
    VALUES ('profile_dependents', p_employee_id, 'pending', v_actor,
      jsonb_build_object('employee_id', p_employee_id, 'effective_from', p_effective_from, 'items', p_items), NOW())
    RETURNING id INTO v_pending_id;
    PERFORM wf_submit(
      p_template_code       => v_template_code,
      p_module_code         => 'profile_dependents',
      p_record_id           => p_employee_id,
      p_metadata            => jsonb_build_object('employee_id', p_employee_id,
        'effective_from', p_effective_from, 'items', p_items),
      p_subject_employee_id => p_employee_id
    );
    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_dependents' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;
    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_id;
    RETURN jsonb_build_object('ok', true, 'workflow', true, 'instance_id', v_instance_id,
      'pending_change_id', v_pending_id, 'effective_from', p_effective_from,
      'change_summary', v_change_summary);
  ELSE
    -- FIX (mig 562): pass v_actor as 4th arg — mig 509 omitted it, causing
    -- "function fn_apply_dependent_set_transition(uuid, date, jsonb) does not exist"
    v_new_set_id := fn_apply_dependent_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

DO $$
BEGIN
  RAISE NOTICE 'Migration 562: submit_dependent_set fixed — v_actor now passed to fn_apply_dependent_set_transition.';
END;
$$;
