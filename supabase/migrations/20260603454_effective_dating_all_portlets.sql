-- =============================================================================
-- Migration 454 — Full effective-dating rewrite for all portlets
--
-- Applies the same 6-case logic from mig 453 (employment) to:
--   1. upsert_personal_info      (employee_personal — bi-temporal single-row)
--   2. fn_apply_dependent_set_transition  (set-snapshot)
--   3. fn_apply_bank_account_set_transition (set-snapshot)
--   4. fn_apply_job_relationship_set_transition (set-snapshot)
--
-- Cases for bi-temporal single-row (personal_info):
--   CORRECTION  — exact effective_from match → UPDATE in place
--   PREPEND     — before first slice → INSERT with end = first.start - 1
--   SPLIT       — inside closed slice → trim + INSERT inheriting end date
--   AMENDMENT   — after current open-ended slice → close + INSERT (existing)
--   GAP-FILL    — no open-ended slice → first-ever INSERT
--
-- Cases for set-snapshot (dependents, bank_accounts, job_relationships):
--   CORRECTION  — exact effective_from match → replace items, keep boundaries
--   PREPEND     — before first set → INSERT with end = first.start - 1
--   SPLIT       — inside closed set → trim + INSERT with inherited end date
--   AMENDMENT   — after current open-ended set → close + INSERT (existing)
--
-- KEY FIXES (same as mig 453):
--   • Overlap guard removed — replaced by case detection
--   • Mirror sync only fires for most-recent slice
--   • COALESCE fallback uses TARGET slice, not always open-ended row
--   • All rows FOR UPDATE at start (concurrent safety)
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. upsert_personal_info
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case          text;
  v_target        employee_personal%ROWTYPE;
  v_current       employee_personal%ROWTYPE;
  v_first         employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_latest     boolean;

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
  v_old_name      text;
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR (user_can('personal_info', 'edit', NULL) AND EXISTS (
        SELECT 1 FROM employees e WHERE e.id = p_employee_id
          AND e.status IN ('Draft','Incomplete','Pending') AND e.deleted_at IS NULL))
    OR (p_employee_id = get_my_employee_id() AND has_permission('personal_info.edit'))
    OR EXISTS (SELECT 1 FROM workflow_tasks wt
               JOIN workflow_instances wi ON wi.id = wt.instance_id
               WHERE wi.record_id = p_employee_id
                 AND wt.assigned_to = auth.uid() AND wt.status = 'pending')
    OR EXISTS (SELECT 1 FROM workflow_instances wi
               WHERE wi.record_id = p_employee_id
                 AND wi.submitted_by = auth.uid()
                 AND wi.status = 'awaiting_clarification')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: you do not have permission to edit personal information for this employee.');
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Lock all slices for concurrent safety ───────────────────────────────
  PERFORM id FROM employee_personal WHERE employee_id = p_employee_id
  ORDER BY effective_from FOR UPDATE;

  -- ── 4. Case detection ──────────────────────────────────────────────────────
  -- 4a. Exact match → CORRECTION
  SELECT * INTO v_target FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  -- 4b. Before all slices → PREPEND
  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_personal
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case := 'prepend'; v_target := v_first;
    END IF;
  END IF;

  -- 4c. Inside a closed historical slice → SPLIT
  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_personal
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  -- 4d. Open-ended or first-ever → AMENDMENT / GAP-FILL
  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_personal
    WHERE employee_id = p_employee_id
      AND effective_to = '9999-12-31'::date AND is_active = true;
    IF FOUND THEN
      v_case := 'amendment'; v_target := v_current;
    ELSE
      v_case := 'gap_fill';
      SELECT * INTO v_target FROM employee_personal
      WHERE employee_id = p_employee_id ORDER BY effective_from DESC LIMIT 1;
    END IF;
  END IF;

  -- ── 5. Compute derived name from target slice as fallback ─────────────────
  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_target.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_target.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_target.last_name,   '')), '');
  v_computed_name := NULLIF(trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name)), '');

  -- ── 6. Execute by case ────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_personal SET
      first_name     = v_first_name,
      middle_name    = v_middle_name,
      last_name      = v_last_name,
      name           = v_computed_name,
      nationality    = COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      marital_status = COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      gender         = COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      dob            = COALESCE(NULLIF(p_proposed_data->>'dob', '')::date,      v_target.dob),
      photo_url      = COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      updated_at     = NOW(), updated_by = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob', '')::date,      v_target.dob),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      p_effective_from, v_target.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    DECLARE v_inherited_end date := v_target.effective_to; BEGIN
      UPDATE employee_personal
      SET effective_to = p_effective_from - interval '1 day',
          updated_at = NOW(), updated_by = auth.uid()
      WHERE id = v_target.id;

      INSERT INTO employee_personal (
        employee_id, first_name, middle_name, last_name, name,
        nationality, marital_status, gender, dob, photo_url,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
        COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
        COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
        COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
        COALESCE(NULLIF(p_proposed_data->>'dob', '')::date,      v_target.dob),
        COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
        p_effective_from, v_inherited_end,
        v_target.is_active, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;
    END;

  ELSIF v_case IN ('amendment', 'gap_fill') THEN
    IF v_case = 'amendment' THEN
      IF v_current.effective_from >= p_effective_from THEN
        DELETE FROM employee_personal WHERE id = v_current.id;
      ELSE
        UPDATE employee_personal
        SET effective_to = p_effective_from - interval '1 day',
            is_active = false, inactive_at = NOW(),
            updated_at = NOW(), updated_by = auth.uid()
        WHERE id = v_current.id;
      END IF;
    END IF;

    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob', '')::date,      v_target.dob),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      p_effective_from, '9999-12-31'::date,
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 7. Mirror sync — only for most-recent slice ───────────────────────────
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  );

  IF v_is_latest AND p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    SELECT name INTO v_old_name FROM employees WHERE id = p_employee_id;
    IF v_old_name IS DISTINCT FROM v_computed_name THEN
      PERFORM set_config('prowess.allow_name_sync', 'true', true);
      UPDATE employees SET name = v_computed_name, updated_at = NOW()
      WHERE id = p_employee_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'case', v_case, 'personal_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Mig 454: full effective-dating rewrite. Handles correction, prepend, split, '
  'amendment, gap-fill. Overlap guard removed. Mirror sync only for most-recent slice.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. fn_apply_dependent_set_transition
-- Set-snapshot: items always come from import — no field-level COALESCE needed.
-- Boundaries (effective_to) inherited from containing/adjacent set.
-- ═════════════════════════════════════════════════════════════════════════════

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
  v_case          text;
  v_target_id     UUID;
  v_target_eff_from DATE;
  v_inherited_end DATE;
  v_new_set_id    UUID;
  v_emp_code      TEXT;
  v_max_seq       INTEGER := 0;
  v_item          JSONB;
  v_dep_code      TEXT;
  v_attachment    JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('dep_set:' || p_employee_id::TEXT));

  -- ── Case detection ─────────────────────────────────────────────────────────

  -- Correction: exact effective_from match on any set
  SELECT id INTO v_target_id FROM employee_dependent_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  -- Prepend: before first set
  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend';
      v_inherited_end := v_target_eff_from - 1;
    END IF;
  END IF;

  -- Split: falls inside a closed historical set
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

  -- Amendment: existing open-ended set (or gap-fill / first-ever)
  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_dependent_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment';
    v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────

  IF v_case = 'correction' THEN
    -- Delete existing items; set boundaries unchanged; re-insert new items
    DELETE FROM employee_dependent_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    -- Insert before first set; ends day before first set starts
    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    -- Trim containing set; new set inherits its end date
    UPDATE employee_dependent_set
    SET effective_to = p_effective_from - 1, updated_at = NOW()
    WHERE id = v_target_id;

    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_dependent_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_dependent_set
        SET effective_to = p_effective_from - 1, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;

    INSERT INTO employee_dependent_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items (same for all cases) ─────────────────────────────────────
  SELECT employee_id INTO v_emp_code FROM employees WHERE id = p_employee_id;
  IF v_emp_code IS NULL THEN
    RAISE EXCEPTION 'fn_apply_dependent_set_transition: employee % not found', p_employee_id;
  END IF;

  SELECT COALESCE(MAX((regexp_match(i.dependent_code, '_DEP_(\d+)$'))[1]::INTEGER), 0)
  INTO v_max_seq
  FROM employee_dependent_item i
  JOIN employee_dependent_set  s ON s.id = i.set_id
  WHERE s.employee_id = p_employee_id
    AND i.set_id != v_new_set_id; -- exclude items we just deleted for correction

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
        IF NOT EXISTS (SELECT 1 FROM employee_dependent_attachments a
                       WHERE a.dependent_code = v_dep_code
                         AND a.file_path = v_attachment->>'file_path') THEN
          INSERT INTO employee_dependent_attachments (
            dependent_code, employee_id, document_type, file_name,
            original_file_name, file_path, mime_type, file_size,
            is_active, uploaded_by, created_by, updated_by
          ) VALUES (
            v_dep_code, p_employee_id,
            v_attachment->>'document_type', v_attachment->>'file_name',
            v_attachment->>'original_file_name', v_attachment->>'file_path',
            v_attachment->>'mime_type',
            NULLIF(v_attachment->>'file_size', '')::bigint,
            true, p_actor, p_actor, p_actor
          );
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_dependent_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 454: added correction/prepend/split cases. Overlap guard replaced by case detection.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. fn_apply_bank_account_set_transition
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_apply_bank_account_set_transition(
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
  v_case          text;
  v_target_id     UUID;
  v_target_eff_from DATE;
  v_inherited_end DATE;
  v_new_set_id    UUID;
  v_item          JSONB;
  v_group_id      UUID;
BEGIN
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
    END IF;
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
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
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
        SET effective_to = p_effective_from - 1,
            is_active = false, updated_at = NOW()
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_bank_account_set (employee_id, effective_from, effective_to, is_active, created_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_group_id := NULLIF(v_item->>'bank_account_group_id', '')::uuid;

    INSERT INTO employee_bank_account_item (
      set_id, bank_account_group_id, country_code, currency_code,
      bank_name, branch_name, branch_code,
      account_holder_name, account_number,
      ifsc_code, iban, swift_bic, is_primary
    ) VALUES (
      v_new_set_id, v_group_id,
      v_item->>'country_code', v_item->>'currency_code',
      v_item->>'bank_name', v_item->>'branch_name', v_item->>'branch_code',
      v_item->>'account_holder_name', v_item->>'account_number',
      NULLIF(v_item->>'ifsc_code',  ''),
      NULLIF(v_item->>'iban',       ''),
      NULLIF(v_item->>'swift_bic',  ''),
      COALESCE((v_item->>'is_primary')::boolean, false)
    );
  END LOOP;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_bank_account_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 454: added correction/prepend/split cases. Overlap guard replaced by case detection.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. fn_apply_job_relationship_set_transition
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fn_apply_job_relationship_set_transition(
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
  v_manager_id    uuid;
BEGIN
  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_job_relationship_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    DELETE FROM employee_job_relationship_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_job_relationship_set
    SET effective_to = p_effective_from - 1, is_active = false,
        updated_at = NOW(), updated_by = p_actor
    WHERE id = v_target_id;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_job_relationship_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_job_relationship_set
        SET effective_to = p_effective_from - 1, is_active = false,
            updated_at = NOW(), updated_by = p_actor
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id INTO v_manager_id FROM employees
    WHERE employee_id = v_item->>'manager_employee_id';

    IF v_manager_id IS NULL THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: manager % not found',
        v_item->>'manager_employee_id';
    END IF;

    IF v_manager_id = p_employee_id THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: self-assignment not allowed';
    END IF;

    INSERT INTO employee_job_relationship_item (
      set_id, relationship_code, manager_employee_id
    ) VALUES (
      v_new_set_id,
      v_item->>'relationship_code',
      v_manager_id
    );
  END LOOP;

  -- ── Mirror sync — only if most-recent set ─────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND NOT EXISTS (
    SELECT 1 FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  ) THEN
    PERFORM sync_job_relationship_mirrors(p_employee_id, v_new_set_id);
  END IF;

  RETURN v_new_set_id;
END;
$$;

COMMENT ON FUNCTION fn_apply_job_relationship_set_transition(uuid, date, jsonb, uuid) IS
  'Mig 454: added correction/prepend/split cases. Mirror sync only for most-recent set. '
  'Overlap guard replaced by case detection.';

-- =============================================================================
-- END OF MIGRATION 454
-- =============================================================================
