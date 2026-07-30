-- =============================================================================
-- Migration 694 — submit_dependent_set: accept p_comment (matches Address / Education)
--
-- CONTEXT
-- ═══════
-- After mig 693 gave Education a routing-preview modal + comment field, we
-- want the same UX for Dependents. wf_submit already accepts p_comment
-- (since mig 506); we just need submit_dependent_set to thread it through.
--
-- IDEMPOTENT: DROP + CREATE with the new signature. The 3-arg overload
-- (from migs 322, 340, 509, 562) is replaced.
-- =============================================================================


-- ── Drop existing 3-arg overload ────────────────────────────────────────────

DROP FUNCTION IF EXISTS submit_dependent_set(uuid, date, jsonb);
DROP FUNCTION IF EXISTS submit_dependent_set(uuid, date, jsonb, text);


-- ── Replace with p_comment-aware version (body copied verbatim from mig 562
--    with only two additions: the parameter, and the p_comment pass to wf_submit)

CREATE OR REPLACE FUNCTION submit_dependent_set(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_comment        TEXT DEFAULT NULL
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

    -- MIG 694 CHANGE: thread p_comment through to wf_submit
    PERFORM wf_submit(
      p_template_code       => v_template_code,
      p_module_code         => 'profile_dependents',
      p_record_id           => p_employee_id,
      p_metadata            => jsonb_build_object('employee_id', p_employee_id,
        'effective_from', p_effective_from, 'items', p_items),
      p_comment             => NULLIF(trim(COALESCE(p_comment, '')), ''),
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
    v_new_set_id := fn_apply_dependent_set_transition(p_employee_id, p_effective_from, p_items, v_actor);
    RETURN jsonb_build_object('ok', true, 'workflow', false, 'set_id', v_new_set_id,
      'effective_from', p_effective_from, 'change_summary', v_change_summary);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_dependent_set(uuid, date, jsonb, text) TO authenticated;

COMMENT ON FUNCTION submit_dependent_set IS
  'Mig 562: v_actor passed to fn_apply_dependent_set_transition. '
  'Mig 694: p_comment param threaded to wf_submit for WorkflowSubmitModal comment support.';


-- ── Verification ────────────────────────────────────────────────────────────
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'submit_dependent_set';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: expected exactly 1 submit_dependent_set overload, found %', v_count;
  END IF;
  RAISE NOTICE 'Migration 694 verified: submit_dependent_set now accepts p_comment.';
END $$;
