-- Migration 341: submit_bank_account_set — empty-set guard + hire pipeline guard
--
-- Same pattern as mig 340 for dependents:
-- 1. Empty-set guard: items=[] with no current active set → noop
-- 2. Hire pipeline guard: Draft/Incomplete/Pending → force PATH A
--    Bank accounts entered during hire are written directly to
--    employee_bank_account_set; no standalone profile_bank workflow task.

CREATE OR REPLACE FUNCTION submit_bank_account_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB
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

  -- ── Empty-set guard ───────────────────────────────────────────────────────
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

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    is_super_admin()
    OR user_can('bank_accounts', 'edit',   p_employee_id)
    OR user_can('bank_accounts', 'create', p_employee_id)
    OR (v_is_hire_pipeline AND user_can('bank_accounts', 'edit', NULL) AND user_can('hire_employee', 'edit', NULL))
  ) THEN
    RAISE EXCEPTION 'Access denied for bank set submission on employee %', p_employee_id USING ERRCODE = '42501';
  END IF;

  -- ── Submission cutoff (ESS only, not hire pipeline) ───────────────────────
  IF NOT v_is_hire_pipeline AND EXTRACT(DAY FROM CURRENT_DATE) > 15
    AND NOT is_super_admin() AND NOT user_can('bank_accounts', 'edit', NULL)
  THEN
    RAISE EXCEPTION 'Bank account changes may only be submitted between the 1st and 15th of the month.';
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_effective_from is required';
  END IF;
  p_effective_from := date_trunc('month', p_effective_from)::date;

  -- ── Per-item validation ───────────────────────────────────────────────────
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

  -- ── Resolve workflow (hire pipeline → PATH A) ─────────────────────────────
  IF v_is_hire_pipeline THEN
    v_template_id := NULL;
  ELSE
    v_template_id := resolve_workflow_for_submission('profile_bank', v_actor);
  END IF;

  IF v_template_id IS NOT NULL THEN
    SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;
    INSERT INTO workflow_pending_changes (module_code, record_id, status, submitted_by, proposed_data, created_at)
    VALUES ('profile_bank', p_employee_id, 'pending', v_actor,
      jsonb_build_object('employee_id', p_employee_id, 'effective_from', p_effective_from, 'items', p_items), NOW())
    RETURNING id INTO v_pending_id;

    PERFORM wf_submit(
      p_template_code => v_template_code, p_module_code => 'profile_bank',
      p_record_id => p_employee_id,
      p_metadata => jsonb_build_object('employee_id', p_employee_id, 'pending_change_id', v_pending_id, 'change_summary', v_change_summary)
    );

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

REVOKE ALL ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) TO authenticated;

COMMENT ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB) IS
  'Mig 341: empty-set guard + hire pipeline guard (force PATH A for Draft/Incomplete/Pending). '
  'Bank accounts entered during hire write directly to employee_bank_account_set.';
