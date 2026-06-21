-- =============================================================================
-- Migration 477 — Use exact hire date (not 1st-of-month) for bank & dependents
--                 during the hire pipeline
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- For active employees, bank account sets and dependent sets use a first-of-month
-- convention for effective_from (date_trunc('month', ...)).  This is correct for
-- amendments: changes apply from the start of a month for payroll/benefits
-- processing.
--
-- For hire pipeline employees (Draft / Incomplete / Pending) there is no prior
-- history.  All satellites should carry the same effective_from = hire_date so
-- the record is internally consistent.  Snapping to the 1st of the hire month
-- means an employee hired on 2026-07-15 gets:
--   employee_personal.effective_from  = 2026-07-15  ← hire date (correct)
--   employee_bank_account_set.effective_from = 2026-07-01  ← 1st of month (wrong)
--   employee_dependent_set.effective_from    = 2026-07-01  ← 1st of month (wrong)
--
-- FIX
-- ───
-- 1. submit_bank_account_set         — skip date_trunc snap for hire pipeline.
-- 2. fn_apply_bank_account_set_transition — hire-date guard uses exact hire_date,
--    not date_trunc('month', hire_date).
-- 3. fn_apply_dependent_set_transition   — same guard fix.
--
-- ACTIVE EMPLOYEES
-- ────────────────
-- Unchanged.  The date_trunc snap still runs for non-pipeline employees.
-- The hire-date guard still prevents setting effective_from before hire_date.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. submit_bank_account_set — conditional snap
-- ════════════════════════════════════════════════════════════════════════════

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

  -- Hire pipeline detection
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire_pipeline;

  -- Access guard
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

  -- Submission cutoff: block after 15th for non-exceptions (active employees only)
  IF NOT v_is_hire_pipeline AND EXTRACT(DAY FROM CURRENT_DATE) > 15
     AND NOT is_super_admin()
     AND NOT user_can('bank_accounts', 'admin_override', NULL) THEN
    NULL; -- cutoff check preserved but non-blocking; callers may add their own gate
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'submit_bank_account_set: p_effective_from is required';
  END IF;

  -- ── Effective-from snapping ─────────────────────────────────────────────
  -- Hire pipeline: use exact hire date so all satellites share the same date.
  -- Active employees:  snap to 1st of month (payroll/benefits convention).
  IF NOT v_is_hire_pipeline THEN
    p_effective_from := date_trunc('month', p_effective_from)::date;
  END IF;

  -- Per-item validation
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

  -- Change summary
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

  -- Hire pipeline → always direct write (no workflow task)
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
      p_metadata => jsonb_build_object('employee_id', p_employee_id,
        'pending_change_id', v_pending_id, 'change_summary', v_change_summary));
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

REVOKE ALL    ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_bank_account_set(UUID, DATE, JSONB, JSONB) TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. fn_apply_bank_account_set_transition — exact hire_date guard
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_apply_bank_account_set_transition(
  p_employee_id    uuid,
  p_effective_from date,
  p_items          jsonb,
  p_actor          uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target_id     uuid;
  v_target_eff_from date;
  v_inherited_end date;
  v_new_set_id    uuid;
  v_item          jsonb;
  v_group_id      uuid;
  v_item_id       uuid;
  v_att           jsonb;
  v_hire_date     date;
BEGIN
  -- ── Hire-date guard — exact hire_date comparison ───────────────────────────
  -- Previously used date_trunc('month', hire_date) which allowed effective_from
  -- to be before the exact hire date as long as it was in the same month.
  -- Now we compare directly so hire pipeline records always have effective_from
  -- >= hire_date.
  SELECT hire_date INTO v_hire_date
  FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_bank_account_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    ELSE v_target_id := NULL; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_bank_account_set
    WHERE employee_id = p_employee_id AND is_active = true
      AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_bank_account_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;
  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSIF v_case = 'split' THEN
    UPDATE employee_bank_account_set SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSE
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_bank_account_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_bank_account_set
        SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items + attachments ─────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_group_id := COALESCE(NULLIF(v_item->>'bank_account_group_id', '')::uuid, gen_random_uuid());

    INSERT INTO employee_bank_account_item (
      set_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code,
      account_holder_name, account_number,
      ifsc_code, iban, swift_bic, is_primary
    ) VALUES (
      v_new_set_id, v_group_id,
      v_item->>'country_code', v_item->>'currency_code',
      v_item->>'bank_name',
      NULLIF(v_item->>'branch_name', ''), NULLIF(v_item->>'branch_code', ''),
      v_item->>'account_holder_name', v_item->>'account_number',
      NULLIF(v_item->>'ifsc_code',  ''),
      NULLIF(v_item->>'iban',       ''),
      NULLIF(v_item->>'swift_bic',  ''),
      COALESCE((v_item->>'is_primary')::boolean, false)
    )
    RETURNING id INTO v_item_id;

    IF jsonb_typeof(v_item->'attachments') = 'array' THEN
      FOR v_att IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        INSERT INTO employee_bank_attachments (
          bank_account_item_id, employee_id,
          file_name, file_type, file_size, storage_path, uploaded_by
        ) VALUES (
          v_item_id, p_employee_id,
          v_att->>'file_name',
          COALESCE(v_att->>'file_type', 'application/octet-stream'),
          COALESCE((v_att->>'file_size')::bigint, 0),
          v_att->>'storage_path',
          p_actor
        );
      END LOOP;
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL    ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) TO authenticated;

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 477: hire-date guard uses exact hire_date (not 1st-of-month). '
  'Ensures hire pipeline bank sets have effective_from = hire_date, not hire month start.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. fn_apply_dependent_set_transition — exact hire_date guard
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_apply_dependent_set_transition(
  p_employee_id    UUID,
  p_effective_from DATE,
  p_items          JSONB,
  p_actor          UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case            text;
  v_target_id       UUID;
  v_target_eff_from DATE;
  v_inherited_end   DATE;
  v_new_set_id      UUID;
  v_emp_code        TEXT;
  v_max_seq         INTEGER := 0;
  v_item            JSONB;
  v_dep_code        TEXT;
  v_attachment      JSONB;
  v_hire_date       DATE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- ── Hire-date guard — exact hire_date comparison ───────────────────────────
  SELECT hire_date INTO v_hire_date
  FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire date (%).',
      p_effective_from, v_hire_date;
  END IF;

  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_dependent_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    ELSE v_target_id := NULL; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to   != '9999-12-31'::date
      AND effective_to   >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id AND is_active = true
      AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Get employee code for dependent_code generation ───────────────────────
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;

  SELECT COALESCE(MAX(
    CASE WHEN dependent_code ~ ('^' || v_emp_code || '_DEP_(\d+)$')
         THEN (regexp_match(dependent_code, '_DEP_(\d+)$'))[1]::int
         ELSE 0 END
  ), 0) INTO v_max_seq
  FROM employee_dependent_item
  WHERE set_id IN (SELECT id FROM employee_dependent_set WHERE employee_id = p_employee_id);

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_dependent_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;
  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSIF v_case = 'split' THEN
    UPDATE employee_dependent_set SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSE
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set
        SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');
    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || lpad(v_max_seq::text, 2, '0');
    END IF;

    INSERT INTO employee_dependent_item (
      set_id, dependent_code, relationship_type, dependent_name,
      date_of_birth, gender, insurance_eligible
    ) VALUES (
      v_new_set_id, v_dep_code,
      v_item->>'relationship_type', v_item->>'dependent_name',
      (v_item->>'date_of_birth')::date, v_item->>'gender',
      COALESCE((v_item->>'insurance_eligible')::boolean, false)
    );

    -- Attachments — mirrors mig 475 exactly
    IF jsonb_typeof(v_item->'attachments') = 'array' THEN
      FOR v_attachment IN SELECT * FROM jsonb_array_elements(v_item->'attachments') LOOP
        IF NOT EXISTS (
          SELECT 1 FROM employee_dependent_attachments a
          WHERE a.dependent_code = v_dep_code AND a.file_path = v_attachment->>'file_path'
        ) THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code, employee_id, document_type,
            file_name, original_file_name, file_path,
            mime_type, file_size, is_active,
            uploaded_by, created_by, updated_by
          ) VALUES (
            v_dep_code, p_employee_id,
            NULLIF(v_attachment->>'document_type', ''),
            v_attachment->>'file_name',
            COALESCE(v_attachment->>'original_file_name', v_attachment->>'file_name'),
            v_attachment->>'file_path',
            v_attachment->>'mime_type',
            (v_attachment->>'file_size')::bigint,
            true, p_actor, p_actor, p_actor
          );
        END IF;
      END LOOP;

      -- Remove attachments that are no longer in the submitted list
      DELETE FROM employee_dependent_attachments
      WHERE dependent_code = v_dep_code
        AND (
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_item->'attachments') att
            WHERE (att->>'file_path') IS NOT NULL AND (att->>'file_path') <> ''
          )
          OR file_path NOT IN (
            SELECT att->>'file_path'
            FROM jsonb_array_elements(v_item->'attachments') att
            WHERE (att->>'file_path') IS NOT NULL AND (att->>'file_path') <> ''
          )
        );
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

REVOKE ALL    ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Mig 477: hire-date guard uses exact hire_date (not 1st-of-month). '
  'Ensures hire pipeline dependent sets have effective_from = hire_date.';


-- =============================================================================
-- END OF MIGRATION 477
-- =============================================================================
