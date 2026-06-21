-- =============================================================================
-- Migration 393 — add workflow task access path (Path D) to portlet RPCs
-- =============================================================================
-- Approvers using the Update button in WorkflowReview hit access denied on:
--   submit_bank_account_set     — can't save bank edits
--   submit_dependent_set        — can't save dependent edits
--   get_employee_bank_account_set_history  — can't view bank history
--   get_employee_dependent_set_history     — can't view dependent history
--
-- Fix: add Path D (pending workflow task) + Path E (sent-back initiator)
-- to each guard. No other logic changes.
-- =============================================================================

-- Helper snippet used in each guard (defined inline, not a separate function)
-- Path D: approver holds a pending task for this employee
-- Path E: initiator whose request was sent back

-- ── 1. submit_bank_account_set ───────────────────────────────────────────────

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
    SELECT 1 FROM employees WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  IF v_item_count = 0 THEN
    IF v_is_hire_pipeline THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM employee_bank_account_set
      WHERE employee_id = p_employee_id AND is_active = true AND effective_to = '9999-12-31'::date
    ) THEN
      RETURN jsonb_build_object('ok', true, 'workflow', false, 'noop', true);
    END IF;
  END IF;

  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'edit',   p_employee_id)
    OR user_can('bank_accounts', 'create', p_employee_id)
    OR (v_is_hire_pipeline AND user_can('bank_accounts', 'edit', NULL) AND user_can('hire_employee', 'edit', NULL))
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
    RAISE EXCEPTION 'Access denied for bank set submission on employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  IF NOT v_is_hire_pipeline AND EXTRACT(DAY FROM CURRENT_DATE) > 15
    AND NOT is_super_admin() AND NOT user_can('bank_accounts', 'edit', NULL)
  THEN
    RAISE EXCEPTION 'Bank account changes may only be submitted between the 1st and 15th of the month.';
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_effective_from is required';
  END IF;
  p_effective_from := date_trunc('month', p_effective_from)::date;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NOT (v_item ? 'bank_name' AND v_item ? 'account_holder_name'
            AND v_item ? 'account_number' AND v_item ? 'country_code' AND v_item ? 'currency_code') THEN
      RAISE EXCEPTION 'submit_bank_account_set: each item must include bank_name, account_holder_name, account_number, country_code, currency_code';
    END IF;
    IF (v_item->>'is_primary')::boolean THEN v_primary_count := v_primary_count + 1; END IF;
    IF (v_item->>'bank_account_group_id') IS NULL THEN v_added_count := v_added_count + 1; END IF;
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;
    IF v_group_id IS NOT NULL THEN
      IF v_group_id = ANY(v_seen_groups) THEN
        RAISE EXCEPTION 'submit_bank_account_set: duplicate bank_account_group_id % in proposed set', v_group_id;
      END IF;
      v_seen_groups := array_append(v_seen_groups, v_group_id);
    END IF;
  END LOOP;

  IF v_item_count > 0 AND v_primary_count <> 1 THEN
    RAISE EXCEPTION 'submit_bank_account_set: exactly one item must have is_primary = true (found %)', v_primary_count;
  END IF;

  SELECT COUNT(*) INTO v_removed_count
  FROM employee_bank_account_item bai
  JOIN employee_bank_account_set  bas ON bas.id = bai.set_id
  WHERE bas.employee_id = p_employee_id AND bas.is_active = true AND bas.effective_to = '9999-12-31'::date
    AND bai.bank_account_group_id <> ALL(
      SELECT COALESCE((j->>'bank_account_group_id')::uuid, gen_random_uuid())
      FROM jsonb_array_elements(p_items) j
    );

  v_change_summary := format('%s added, %s removed, %s accounts in proposed set', v_added_count, v_removed_count, v_item_count);

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
    PERFORM wf_submit(p_template_code => v_template_code, p_module_code => 'profile_bank',
      p_record_id => p_employee_id,
      p_metadata => jsonb_build_object('employee_id', p_employee_id, 'pending_change_id', v_pending_id, 'change_summary', v_change_summary));
    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_bank' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;
    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_id;
    RETURN jsonb_build_object('ok', true, 'workflow', true, 'instance_id', v_instance_id,
      'pending_change_id', v_pending_id, 'effective_from', p_effective_from, 'change_summary', v_change_summary);
  ELSE
    v_new_set_id := fn_apply_bank_account_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) TO authenticated;

-- ── 2. submit_dependent_set — add Path D + E ─────────────────────────────────

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

  v_change_summary := format('%s added, %s removed, %s dependents in proposed set', v_added_count, v_removed_count, v_item_count);

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
    PERFORM wf_submit(p_template_code => v_template_code, p_module_code => 'profile_dependents',
      p_record_id => p_employee_id,
      p_metadata => jsonb_build_object('employee_id', p_employee_id, 'pending_change_id', v_pending_id, 'change_summary', v_change_summary));
    SELECT id INTO v_instance_id FROM workflow_instances
    WHERE module_code = 'profile_dependents' AND record_id = p_employee_id
      AND status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC LIMIT 1;
    UPDATE workflow_pending_changes SET instance_id = v_instance_id WHERE id = v_pending_id;
    RETURN jsonb_build_object('ok', true, 'workflow', true, 'instance_id', v_instance_id,
      'pending_change_id', v_pending_id, 'effective_from', p_effective_from, 'change_summary', v_change_summary);
  ELSE
    v_new_set_id := fn_apply_dependent_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_dependent_set(UUID, DATE, JSONB) TO authenticated;

-- ── 3. get_employee_bank_account_set_history — add Path D + E ────────────────

CREATE OR REPLACE FUNCTION get_employee_bank_account_set_history(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_sets JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'history', p_employee_id)
    OR user_can('bank_accounts', 'view',    p_employee_id)
    OR user_can('bank_accounts', 'edit',    p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('employee.view_bank_accounts')
    )
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
    RAISE EXCEPTION 'get_employee_bank_account_set_history: access denied for employee %', p_employee_id
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'set_id',         s.id,
        'effective_from', s.effective_from,
        'effective_to',   s.effective_to,
        'is_active',      s.is_active,
        'created_at',     s.created_at,
        'item_count',     COALESCE(ic.cnt, 0),
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'bank_name',           i.bank_name,
            'account_number',      i.account_number,
            'account_holder_name', i.account_holder_name,
            'currency_code',       i.currency_code,
            'is_primary',          i.is_primary
          ) ORDER BY i.is_primary DESC, i.bank_name)
          FROM employee_bank_account_item i WHERE i.set_id = s.id
        ), '[]'::jsonb)
      )
      ORDER BY s.effective_from DESC
    ),
    '[]'::jsonb
  )
    INTO v_sets
  FROM employee_bank_account_set s
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS cnt
    FROM employee_bank_account_item WHERE set_id = s.id
  ) ic ON true
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'sets', v_sets);
END;
$$;

REVOKE ALL ON FUNCTION get_employee_bank_account_set_history(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_bank_account_set_history(UUID) TO authenticated;

-- ── 4. get_employee_dependent_set_history — add Path D + E ───────────────────

CREATE OR REPLACE FUNCTION get_employee_dependent_set_history(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_sets JSONB;
BEGIN
  IF NOT (
    is_super_admin()
    OR user_can('dependents', 'history', p_employee_id)
    OR user_can('dependents', 'view',    p_employee_id)
    OR (
      user_can('dependents', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
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

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'set_id',         s.id,
        'effective_from', s.effective_from,
        'effective_to',   s.effective_to,
        'is_active',      s.is_active,
        'created_at',     s.created_at,
        'item_count',     COALESCE(ic.cnt, 0)
      )
      ORDER BY s.effective_from DESC
    ),
    '[]'::jsonb
  )
    INTO v_sets
  FROM employee_dependent_set s
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS cnt
    FROM employee_dependent_item WHERE set_id = s.id
  ) ic ON true
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object('ok', true, 'sets', v_sets);
END;
$$;

REVOKE ALL ON FUNCTION get_employee_dependent_set_history(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_dependent_set_history(UUID) TO authenticated;

COMMENT ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB)        IS 'Mig 393: added Path D+E (workflow task/initiator access) to allow approvers to save bank edits via Update button.';
COMMENT ON FUNCTION submit_dependent_set(UUID, DATE, JSONB)                  IS 'Mig 393: added Path D+E (workflow task/initiator access) to allow approvers to save dependent edits via Update button.';
COMMENT ON FUNCTION get_employee_bank_account_set_history(UUID)              IS 'Mig 393: added Path D+E so approvers can view bank history in workflow review.';
COMMENT ON FUNCTION get_employee_dependent_set_history(UUID)                 IS 'Mig 393: added Path D+E so approvers can view dependent history in workflow review.';
