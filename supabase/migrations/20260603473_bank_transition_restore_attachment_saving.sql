-- Migration 473: restore attachment saving in fn_apply_bank_account_set_transition
--
-- Root cause chain:
--   Mig 390 added a 5-param overload that saved per-item attachments to
--   employee_bank_attachments (joining via bank_account_item_id).
--   Mig 465 dropped the 5-param overload (to fix an ambiguity error).
--   Mig 467 restored the 4-param version with gen_random_uuid() fix but
--   WITHOUT the attachment loop — so attachments were uploaded to storage
--   but never written to employee_bank_attachments, making them invisible
--   on the next load.
--
-- Fix: add v_item_id capture (RETURNING id) and the per-item attachment
--   INSERT loop to the 4-param function, matching mig 390's logic exactly.

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
  v_item_id       uuid;   -- item row id, needed for attachment FK
  v_att           jsonb;
  v_hire_date     date;
BEGIN
  -- ── Hire-date guard ────────────────────────────────────────────────────────
  SELECT hire_date INTO v_hire_date FROM employees WHERE id = p_employee_id;
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
    -- Items cascade-delete their attachments; we re-insert everything fresh.
    DELETE FROM employee_bank_account_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_bank_account_set
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
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

  -- ── Insert items + their attachments ───────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- Auto-generate group_id for new accounts; carry existing id for known ones.
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

    -- Save per-item attachments (embedded in p_items[i].attachments).
    -- Both newly uploaded files and existing ones (re-linked by storage_path)
    -- are included by the frontend on every save.
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
  'Mig 473: restored per-item attachment saving (RETURNING id → employee_bank_attachments). '
  'Includes hire-date guard (mig 456) and gen_random_uuid() for new accounts (mig 467).';
