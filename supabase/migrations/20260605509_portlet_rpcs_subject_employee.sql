-- =============================================================================
-- Migration 509: submit_bank_account_set + submit_dependent_set
--                — pass p_subject_employee_id to wf_submit
--
-- These RPCs call wf_submit directly (not via submit_change_request), so mig 506
-- did not automatically thread initiated_by_actor_id. This migration patches the
-- wf_submit calls in both functions to pass p_subject_employee_id = p_employee_id,
-- which causes wf_submit to stamp initiated_by_actor_id when HR (actor) submits
-- for a different employee (subject).
--
-- Only the wf_submit call lines differ from the prior migrations; all other logic
-- is reproduced verbatim.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. submit_bank_account_set — add p_subject_employee_id to wf_submit call
--    Source: mig 477 (hire_exact_effective_date), single change at the wf_submit line
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION submit_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_attachments    JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              UUID := auth.uid();
  v_item_count         INTEGER;
  v_item               JSONB;
  v_primary_count      INTEGER := 0;
  v_added_count        INTEGER := 0;
  v_removed_count      INTEGER := 0;
  v_template_id        UUID;
  v_template_code      TEXT;
  v_pending_id         UUID;
  v_instance_id        UUID;
  v_new_set_id         UUID;
  v_change_summary     TEXT;
  v_group_id           UUID;
  v_seen_groups        UUID[] := '{}';
  v_is_hire_pipeline   BOOLEAN := false;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_items must be a JSONB array';
  END IF;

  v_item_count := jsonb_array_length(p_items);

  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'edit',   p_employee_id)
    OR user_can('bank_accounts', 'create', p_employee_id)
    OR (v_is_hire_pipeline AND user_can('bank_accounts', 'edit', NULL) AND user_can('hire_employee', 'edit', NULL))
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id = p_employee_id AND wt.assigned_to = auth.uid() AND wt.status = 'pending'
    )
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id = p_employee_id AND wi.submitted_by = auth.uid()
        AND wi.status = 'awaiting_clarification'
    )
  ) THEN
    RAISE EXCEPTION 'Access denied for employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  IF NOT v_is_hire_pipeline AND EXTRACT(DAY FROM CURRENT_DATE) > 15
     AND NOT is_super_admin()
     AND NOT user_can('bank_accounts', 'admin_override', NULL) THEN
    NULL;
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_effective_from is required';
  END IF;

  IF NOT v_is_hire_pipeline THEN
    p_effective_from := date_trunc('month', p_effective_from)::date;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'bank_name' AND v_item ? 'account_holder_name'
            AND v_item ? 'account_number' AND v_item ? 'country_code' AND v_item ? 'currency_code') THEN
      RAISE EXCEPTION 'submit_bank_account_set: each item must include bank_name, account_holder_name, account_number, country_code, currency_code';
    END IF;
    IF (v_item->>'is_primary')::boolean THEN v_primary_count := v_primary_count + 1; END IF;
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;
    IF v_group_id IS NOT NULL THEN
      IF v_group_id = ANY(v_seen_groups) THEN
        RAISE EXCEPTION 'submit_bank_account_set: duplicate bank_account_group_id % in proposed set', v_group_id;
      END IF;
      v_seen_groups := array_append(v_seen_groups, v_group_id);
    END IF;
  END LOOP;

  IF v_item_count > 0 AND v_primary_count != 1 THEN
    RAISE EXCEPTION 'submit_bank_account_set: exactly one account must be marked is_primary (found %)', v_primary_count;
  END IF;

  SELECT COUNT(*) INTO v_removed_count
  FROM employee_bank_account_item i
  JOIN employee_bank_account_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id AND s.is_active = true AND s.effective_to = '9999-12-31'::date
    AND i.bank_account_group_id <> ALL(
      SELECT COALESCE(NULLIF(j->>'bank_account_group_id','')::uuid, gen_random_uuid())
      FROM jsonb_array_elements(p_items) j
      WHERE j->>'bank_account_group_id' IS NOT NULL
    );

  SELECT COUNT(*) INTO v_added_count FROM jsonb_array_elements(p_items) j
  WHERE j->>'bank_account_group_id' IS NULL OR (j->>'bank_account_group_id') = '';

  v_change_summary := format('%s added, %s removed, %s accounts in proposed set',
    v_added_count, v_removed_count, v_item_count);

  IF v_is_hire_pipeline THEN
    v_template_id := NULL;
  ELSE
    v_template_id := resolve_workflow_for_submission('profile_bank', v_actor);
  END IF;

  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;
    INSERT INTO workflow_pending_changes (module_code, record_id, status, submitted_by, proposed_data, created_at)
    VALUES ('profile_bank', p_employee_id, 'pending', v_actor,
      jsonb_build_object('employee_id', p_employee_id, 'effective_from', p_effective_from,
        'items', p_items, 'attachments', p_attachments), NOW())
    RETURNING id INTO v_pending_id;
    -- mig 509: pass p_subject_employee_id so initiated_by_actor_id is stamped when HR submits for another employee
    PERFORM wf_submit(
      p_template_code       => v_template_code,
      p_module_code         => 'profile_bank',
      p_record_id           => p_employee_id,
      p_metadata            => jsonb_build_object('employee_id', p_employee_id,
        'pending_change_id', v_pending_id, 'change_summary', v_change_summary),
      p_subject_employee_id => p_employee_id
    );
    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_bank' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;
    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_id;
    RETURN jsonb_build_object('ok', true, 'workflow', true, 'instance_id', v_instance_id,
      'pending_change_id', v_pending_id, 'effective_from', p_effective_from,
      'change_summary', v_change_summary);
  ELSE
    v_new_set_id := fn_apply_bank_account_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. submit_dependent_set — same patch
--    Source: mig 393 (portlet_rpcs_approver_access), single change at wf_submit
-- ─────────────────────────────────────────────────────────────────────────────
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
    -- mig 509: pass p_subject_employee_id so initiated_by_actor_id is stamped when HR submits for another employee
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
    v_new_set_id := fn_apply_dependent_set_transition(p_employee_id, p_effective_from, p_items);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

-- =============================================================================
-- END OF MIGRATION 509
-- =============================================================================
