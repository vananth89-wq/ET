-- Migration 475: fix hire-date guard in fn_apply_dependent_set_transition
--
-- Problem: submit_dependent_set snaps p_effective_from to the 1st of the month,
--   but the hire-date guard compared against the raw hire_date. If hire_date is
--   e.g. 2025-02-02, the snapped effective_from is 2025-02-01, which is less than
--   the hire date → guard rejects it even though it's the same month.
--
-- Fix: compare p_effective_from against date_trunc('month', hire_date) — i.e.
--   the 1st of the hire month — consistent with submit_dependent_set's snapping.
--   Apply the same fix to the bank transition function for consistency.

-- ── Dependents ────────────────────────────────────────────────────────────────

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

  -- ── Hire-date guard (compare against 1st of hire month, not raw date) ───────
  SELECT date_trunc('month', hire_date)::date INTO v_hire_date
  FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire month (%).',
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
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_dependent_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;
  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSIF v_case = 'split' THEN
    UPDATE employee_dependent_set SET effective_to = p_effective_from - 1, updated_at = NOW() WHERE id = v_target_id;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSE
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set SET effective_to = p_effective_from - 1, updated_at = NOW() WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── dep_code sequence ──────────────────────────────────────────────────────
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;
  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  SELECT COALESCE(MAX((regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER), 0)
  INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id AND i.set_id != v_new_set_id;

  -- ── Insert items + attachments ─────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dep_code := NULLIF(v_item->>'dependent_code', '');
    IF v_dep_code IS NULL THEN
      v_max_seq  := v_max_seq + 1;
      v_dep_code := v_emp_code || '_DEP_' || LPAD(v_max_seq::TEXT, 2, '0');
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
GRANT EXECUTE ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) TO authenticated;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(UUID, DATE, JSONB, UUID) IS
  'Mig 475: hire-date guard now compares against 1st of hire month (consistent with '
  'submit_dependent_set month-snap). All features from mig 474 preserved. '
  'See docs/db-functions/fn_apply_dependent_set_transition.md.';


-- ── Bank (same fix) ───────────────────────────────────────────────────────────

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
  -- ── Hire-date guard (compare against 1st of hire month) ───────────────────
  SELECT date_trunc('month', hire_date)::date INTO v_hire_date
  FROM employees WHERE id = p_employee_id;
  IF v_hire_date IS NOT NULL AND p_effective_from < v_hire_date THEN
    RAISE EXCEPTION 'Effective date (%) cannot be before the hire month (%).',
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
    UPDATE employee_bank_account_set SET effective_to = p_effective_from - 1, updated_at = NOW() WHERE id = v_target_id;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;
  ELSE
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_bank_account_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_bank_account_set SET effective_to = p_effective_from - 1, is_active = false, updated_at = NOW() WHERE id = v_target_id;
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
GRANT EXECUTE ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) TO authenticated;

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 475: hire-date guard now compares against 1st of hire month. '
  'All features from mig 473 preserved. '
  'See docs/db-functions/fn_apply_bank_account_set_transition.md.';
