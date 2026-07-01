-- =============================================================================
-- Mig 648: fix upsert_personal_info — gap insert between existing records
--
-- Bug: when p_effective_from falls BEFORE the open record's effective_from
-- (e.g. insert at 2026-06-17, open record at 2026-06-30), the code deleted the
-- 2026-06-30 record and replaced it with a record at 2026-06-17→9999-12-31
-- carrying the 2026-06-30 data. The 2026-06-30 record was lost.
--
-- Fix: when v_current_row.effective_from > p_effective_from, do NOT delete
-- v_current_row. Instead:
--   1. If a closed record covers p_effective_from → split it at p_effective_from.
--   2. Otherwise (gap) → insert p_effective_from → v_current_row.effective_from-1.
-- In both sub-cases the open record (v_current_row) is left untouched.
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date,
  p_propagate      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exact_row      employee_personal%ROWTYPE;
  v_current_row    employee_personal%ROWTYPE;
  v_split_row      employee_personal%ROWTYPE;   -- closed record that covers p_effective_from
  v_new_id         uuid;
  v_new_eff_to     date;
  v_case           text;
  v_is_hire        boolean;
  v_is_system_path boolean := false;

  v_first_name     text;
  v_middle_name    text;
  v_last_name      text;
  v_computed_name  text;
BEGIN

  -- ── 1a. Access guard (Layer-A coarse) ────────────────────────────────────────
  IF auth.uid() IS NULL THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path AND user_can('personal_info', 'bulk_import', NULL) THEN
    v_is_system_path := true;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id   = p_employee_id
        AND wi.module_code IN ('employee_hire','employee_onboarding')
        AND wi.status      IN ('draft','pending','incomplete')
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_tasks wt
      JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id   = p_employee_id
        AND wt.assigned_to = auth.uid()
        AND wt.status      = 'pending'
    ) THEN v_is_system_path := true; END IF;
  END IF;
  IF NOT v_is_system_path THEN
    IF EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id    = p_employee_id
        AND wi.submitted_by = auth.uid()
        AND wi.status       = 'awaiting_clarification'
    ) THEN v_is_system_path := true; END IF;
  END IF;

  IF NOT v_is_system_path THEN
    IF NOT (
      user_can('personal_info', 'edit',   p_employee_id)
      OR user_can('personal_info', 'create', p_employee_id)
      OR (p_employee_id = get_my_employee_id()
          AND (has_permission('personal_info.edit') OR has_permission('personal_info.create')))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Access denied: you do not have permission to edit personal information for this employee.');
    END IF;
  END IF;

  -- ── 2. Input validation ──────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;
  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- ── 3. Detect hire pipeline ──────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── 4. Case detection ────────────────────────────────────────────────────────
  -- 4a. Exact match → correction
  SELECT * INTO v_exact_row
  FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN
    v_case := 'correction';
  END IF;

  -- 4b. Before the first record → prepend
  IF v_case IS NULL THEN
    DECLARE v_first employee_personal%ROWTYPE; BEGIN
      SELECT * INTO v_first FROM employee_personal
      WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
      IF FOUND AND p_effective_from < v_first.effective_from THEN
        v_case := 'prepend';
        v_current_row := v_first;
      END IF;
    END;
  END IF;

  -- 4c. Open-ended record exists → amendment (or gap-insert before it)
  IF v_case IS NULL THEN
    SELECT * INTO v_current_row
    FROM employee_personal
    WHERE employee_id  = p_employee_id
      AND effective_to = '9999-12-31'::date
      AND is_active    = true
    FOR UPDATE;
    IF FOUND THEN
      v_case := 'amendment';
    ELSE
      v_case := 'gap_fill';
    END IF;
  END IF;

  -- ── 1b. Layer-B fine-grained access guard ────────────────────────────────────
  IF NOT v_is_system_path THEN
    IF v_case = 'correction' THEN
      IF NOT (
        user_can('personal_info', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id() AND has_permission('personal_info.edit'))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: personal_info.edit permission is required to edit an existing record.');
      END IF;
    ELSE
      IF NOT (
        user_can('personal_info', 'create', p_employee_id)
        OR user_can('personal_info', 'edit', p_employee_id)
        OR (p_employee_id = get_my_employee_id()
            AND (has_permission('personal_info.create') OR has_permission('personal_info.edit')))
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Access denied: personal_info.create permission is required to insert a new personal info record.');
      END IF;
    END IF;
  END IF;

  -- ── 5. Derive name fields ────────────────────────────────────────────────────
  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  v_exact_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, v_exact_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   v_exact_row.last_name,   '')), '');
  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  -- ── 6. Execute by case ───────────────────────────────────────────────────────

  IF v_case = 'correction' THEN
    UPDATE employee_personal SET
      first_name     = v_first_name,
      middle_name    = v_middle_name,
      last_name      = v_last_name,
      name           = v_computed_name,
      nationality    = COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_exact_row.nationality),
      marital_status = COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_exact_row.marital_status),
      gender         = COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_exact_row.gender),
      dob            = COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_exact_row.dob),
      photo_url      = COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_exact_row.photo_url),
      updated_at     = NOW(), updated_by = auth.uid()
    WHERE id = v_exact_row.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
      p_effective_from,
      v_current_row.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'amendment' THEN

    IF v_is_hire THEN
      -- Hire pipeline: replace the single draft record entirely
      DELETE FROM employee_personal WHERE id = v_current_row.id;
      INSERT INTO employee_personal (
        employee_id, first_name, middle_name, last_name, name,
        nationality, marital_status, gender, dob, photo_url,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
        COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
        COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
        COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
        COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
        COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
        p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;

    ELSIF v_current_row.effective_from > p_effective_from THEN
      -- ── Gap-insert BEFORE the open record ────────────────────────────────────
      -- The open record (v_current_row) must remain untouched.
      -- Check whether a closed record already covers p_effective_from:
      --   yes → split it; no → plain gap fill between closed records.

      SELECT * INTO v_split_row
      FROM employee_personal
      WHERE employee_id    = p_employee_id
        AND is_active      = true
        AND effective_from <= p_effective_from
        AND effective_to   >= p_effective_from
        AND id             != v_current_row.id
      LIMIT 1;

      IF FOUND THEN
        -- Split the covering closed record at p_effective_from.
        -- The tail (p_effective_from → original end) becomes the new record.
        -- The head (original start → p_effective_from - 1) stays in place.
        v_new_eff_to := v_split_row.effective_to;
        UPDATE employee_personal
        SET effective_to = p_effective_from - interval '1 day',
            updated_by   = auth.uid(), updated_at = NOW()
        WHERE id = v_split_row.id;

        -- Derive name fields from split record as base (not from open v_current_row)
        v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_split_row.first_name,  '')), '');
        v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_split_row.middle_name, '')), '');
        v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_split_row.last_name,   '')), '');
        v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
        IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

        INSERT INTO employee_personal (
          employee_id, first_name, middle_name, last_name, name,
          nationality, marital_status, gender, dob, photo_url,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
          COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_split_row.nationality),
          COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_split_row.marital_status),
          COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_split_row.gender),
          COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_split_row.dob),
          COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_split_row.photo_url),
          p_effective_from, v_new_eff_to, true, auth.uid(), auth.uid()
        ) RETURNING id INTO v_new_id;

      ELSE
        -- Pure gap between closed records and the open record.
        -- Find the most recent closed record before v_current_row for base values.
        DECLARE v_gap_base employee_personal%ROWTYPE; BEGIN
          SELECT * INTO v_gap_base
          FROM employee_personal
          WHERE employee_id  = p_employee_id
            AND is_active    = true
            AND effective_to < v_current_row.effective_from
          ORDER BY effective_from DESC LIMIT 1;
        END;

        -- Re-derive names from gap base (ignore v_current_row values)
        v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_gap_base.first_name,  '')), '');
        v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_gap_base.middle_name, '')), '');
        v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_gap_base.last_name,   '')), '');
        v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
        IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

        INSERT INTO employee_personal (
          employee_id, first_name, middle_name, last_name, name,
          nationality, marital_status, gender, dob, photo_url,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
          COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_gap_base.nationality),
          COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_gap_base.marital_status),
          COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_gap_base.gender),
          COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_gap_base.dob),
          COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_gap_base.photo_url),
          p_effective_from,
          v_current_row.effective_from - interval '1 day',
          true, auth.uid(), auth.uid()
        ) RETURNING id INTO v_new_id;
      END IF;

    ELSE
      -- Normal forward amendment: new record starts at p_effective_from,
      -- closes the current open record.
      IF EXISTS (
        SELECT 1 FROM employee_personal
        WHERE employee_id  = p_employee_id
          AND is_active    = true
          AND effective_to < '9999-12-31'::date
          AND effective_to >= p_effective_from
      ) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'The chosen effective date overlaps with an existing historical record. Choose a later date.');
      END IF;
      UPDATE employee_personal
      SET effective_to = p_effective_from - interval '1 day',
          updated_by = auth.uid(), updated_at = NOW()
      WHERE id = v_current_row.id;

      INSERT INTO employee_personal (
        employee_id, first_name, middle_name, last_name, name,
        nationality, marital_status, gender, dob, photo_url,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
        COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
        COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
        COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
        COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
        COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
        p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;
    END IF;

  ELSE -- gap_fill (no open-ended record at all)
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, marital_status, gender, dob, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      NULLIF(p_proposed_data->>'nationality',    ''),
      NULLIF(p_proposed_data->>'marital_status', ''),
      NULLIF(p_proposed_data->>'gender',         ''),
      NULLIF(p_proposed_data->>'dob',            '')::date,
      NULLIF(p_proposed_data->>'photo_url',      ''),
      p_effective_from, '9999-12-31'::date, true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 7. Propagation ──────────────────────────────────────────────────────────
  IF p_propagate THEN
    UPDATE employee_personal SET
      first_name = CASE
        WHEN (p_proposed_data ? 'first_name') AND NULLIF(p_proposed_data->>'first_name','') IS NOT NULL
        THEN v_first_name ELSE first_name END,
      middle_name = CASE
        WHEN (p_proposed_data ? 'middle_name')
        THEN v_middle_name ELSE middle_name END,
      last_name = CASE
        WHEN (p_proposed_data ? 'last_name') AND NULLIF(p_proposed_data->>'last_name','') IS NOT NULL
        THEN v_last_name ELSE last_name END,
      name = CASE
        WHEN (p_proposed_data ? 'first_name') OR (p_proposed_data ? 'last_name')
        THEN v_computed_name ELSE name END,
      nationality = CASE
        WHEN (p_proposed_data ? 'nationality') AND NULLIF(p_proposed_data->>'nationality','') IS NOT NULL
        THEN p_proposed_data->>'nationality' ELSE nationality END,
      marital_status = CASE
        WHEN (p_proposed_data ? 'marital_status') AND NULLIF(p_proposed_data->>'marital_status','') IS NOT NULL
        THEN p_proposed_data->>'marital_status' ELSE marital_status END,
      gender = CASE
        WHEN (p_proposed_data ? 'gender') AND NULLIF(p_proposed_data->>'gender','') IS NOT NULL
        THEN p_proposed_data->>'gender' ELSE gender END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE employee_id    = p_employee_id
      AND id             != COALESCE(v_new_id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from > p_effective_from;
  END IF;

  -- ── 8. Sync employees.name ───────────────────────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    PERFORM set_config('prowess.allow_name_sync', 'true', true);
    UPDATE employees
    SET name = v_computed_name, updated_at = NOW()
    WHERE id = p_employee_id
      AND (name IS DISTINCT FROM v_computed_name);
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_new_id, 'case', v_case);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date, boolean) IS
  'Mig 648: when p_effective_from < open record effective_from (gap insert), '
  'split the covering closed record instead of deleting the open record. '
  'Open record is now always preserved in this scenario.';
