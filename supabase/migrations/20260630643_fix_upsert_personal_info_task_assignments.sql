-- =============================================================================
-- Mig 643: fix upsert_personal_info — remove workflow_task_assignments ref
--
-- workflow_task_assignments does not exist; the access guard block that
-- referenced it is redundant (workflow_tasks covers the same path).
-- Remove the stale block entirely.
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
  v_new_id         uuid;
  v_case           text;
  v_is_hire        boolean;
  v_is_system_path boolean := false;

  v_first_name     text;
  v_middle_name    text;
  v_last_name      text;
  v_computed_name  text;
BEGIN

  -- ── 1a. Access guard (Layer-A coarse) ────────────────────────────────────────
  IF user_can('personal_info', 'bulk_import', NULL) THEN
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
  SELECT * INTO v_exact_row
  FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN
    v_case := 'correction';
  END IF;

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

  -- ── 6. Execute by case ──────────────────────────────────────────────────────
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
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSIF v_current_row.effective_from >= p_effective_from THEN
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSE
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
    END IF;
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

  ELSE -- gap_fill
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
  'Mig 643: removed stale workflow_task_assignments reference (table does not exist). '
  'Access guard now uses only workflow_tasks + workflow_instances.';
