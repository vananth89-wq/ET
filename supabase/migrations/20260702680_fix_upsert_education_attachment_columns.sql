-- =============================================================================
-- Mig 680: fix upsert_education attachment INSERT/UPDATE column names
--
-- ROOT CAUSE
-- ----------
-- Mig 662 attachment loop uses wrong column names against employee_education_attachments:
--   • UPDATE: `doc_type` → should be `document_type`
--             `updated_at` → column does not exist on this table
--   • INSERT: `doc_type` → should be `document_type`
--             Missing NOT NULL columns: original_file_name, mime_type, file_size
--
-- Frontend sends per attachment:
--   { id?, document_type, file_name, original_file_name, file_path,
--     mime_type, file_size, _removed? }
--
-- employee_education_attachments columns (mig 395):
--   document_type, file_name, original_file_name, file_path,
--   mime_type, file_size, uploaded_by, created_by, is_active, uploaded_at, created_at
--   (NO updated_at column)
--
-- FIX
-- ---
-- Full replace of upsert_education — identical to mig 662 except the
-- attachment loop is corrected:
--   1. doc_type        → document_type
--   2. removed updated_at from UPDATE (column doesn't exist)
--   3. INSERT supplies original_file_name, mime_type, file_size
--   4. Handles _removed flag for soft-delete (is_active = false)
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid    DEFAULT NULL,
  p_force_path_a   boolean DEFAULT false   -- set true when called from trigger
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              uuid  := auth.uid();
  v_is_path_a          boolean;
  v_is_hire            boolean;
  v_has_wf_assignment  boolean;
  v_edu_id             uuid;
  v_education_level    text;
  v_degree             text;
  v_institution        text;
  v_start_date         date;
  v_end_date           date;
  v_completion_status  text;
  v_grade_or_gpa       text;
  v_is_highest         boolean;
  v_att                jsonb;
  v_att_id             uuid;
  v_submit_result      jsonb;
BEGIN

  -- ── Access check ─────────────────────────────────────────────────────────────
  IF NOT (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR user_can('education', 'view',   p_employee_id)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- ── Hire pipeline? ───────────────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── Workflow assignment exists? ───────────────────────────────────────────────
  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);

  -- ── Path resolution ──────────────────────────────────────────────────────────
  -- PATH A (direct write): forced (trigger), hire pipeline, or no workflow configured
  -- PATH B (workflow):     normal call + active employee + workflow assignment
  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  -- ── Extract + validate fields ────────────────────────────────────────────────
  v_education_level   := p_education_data->>'education_level';
  v_degree            := NULLIF(trim(p_education_data->>'degree'),       '');
  v_institution       := NULLIF(trim(p_education_data->>'institution'),  '');
  v_start_date        := NULLIF(p_education_data->>'start_date', '')::date;
  v_end_date          := NULLIF(p_education_data->>'end_date',   '')::date;
  v_completion_status := p_education_data->>'completion_status';
  v_grade_or_gpa      := NULLIF(trim(p_education_data->>'grade_or_gpa'), '');
  v_is_highest        := COALESCE((p_education_data->>'is_highest_qualification')::boolean, false);

  IF v_education_level IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'education_level is required.');
  END IF;
  IF v_degree IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'degree is required.');
  END IF;
  IF v_institution IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'institution is required.');
  END IF;
  IF v_start_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'start_date is required.');
  END IF;
  IF v_completion_status IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'completion_status is required.');
  END IF;
  IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'end_date must be on or after start_date.');
  END IF;
  IF v_completion_status = 'ES01' THEN
    IF v_end_date IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date is required for Completed qualifications.');
    END IF;
    IF v_end_date > CURRENT_DATE THEN
      RETURN jsonb_build_object('ok', false, 'error', 'end_date cannot be in the future for Completed qualifications.');
    END IF;
  END IF;

  -- ── PATH B: stage via workflow ───────────────────────────────────────────────
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => p_education_data,
      p_action              => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END,
      p_subject_employee_id => p_employee_id
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'workflow',          true,
      'instance_id',       v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- ── PATH A: direct write ─────────────────────────────────────────────────────
  IF v_is_highest THEN
    UPDATE employee_education
    SET    is_highest_qualification = false, updated_by = v_actor, updated_at = NOW()
    WHERE  employee_id = p_employee_id AND is_highest_qualification = true
      AND  is_active = true
      AND  (p_education_id IS NULL OR id <> p_education_id);
  END IF;

  IF p_education_id IS NOT NULL THEN
    UPDATE employee_education SET
      education_level          = v_education_level,
      degree                   = v_degree,
      institution              = v_institution,
      start_date               = v_start_date,
      end_date                 = v_end_date,
      completion_status        = v_completion_status,
      grade_or_gpa             = v_grade_or_gpa,
      is_highest_qualification = v_is_highest,
      updated_by               = v_actor,
      updated_at               = NOW()
    WHERE id = p_education_id AND employee_id = p_employee_id AND is_active = true
    RETURNING id INTO v_edu_id;

    IF v_edu_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already deleted.');
    END IF;
  ELSE
    INSERT INTO employee_education (
      employee_id, education_level, degree, institution,
      start_date, end_date, completion_status, grade_or_gpa,
      is_highest_qualification, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_education_level, v_degree, v_institution,
      v_start_date, v_end_date, v_completion_status, v_grade_or_gpa,
      v_is_highest, true, v_actor, v_actor
    ) RETURNING id INTO v_edu_id;
  END IF;

  -- ── Handle attachments ────────────────────────────────────────────────────────
  -- Frontend sends: id?, document_type, file_name, original_file_name,
  --                 file_path, mime_type, file_size, _removed?
  FOR v_att IN SELECT * FROM jsonb_array_elements(COALESCE(p_education_data->'attachments', '[]'::jsonb))
  LOOP
    -- Soft-delete removed attachments
    IF (v_att->>'_removed')::boolean IS TRUE THEN
      v_att_id := NULLIF(v_att->>'id', '')::uuid;
      IF v_att_id IS NOT NULL THEN
        UPDATE employee_education_attachments
        SET    is_active = false
        WHERE  id = v_att_id AND education_id = v_edu_id;
      END IF;
      CONTINUE;
    END IF;

    v_att_id := NULLIF(v_att->>'id', '')::uuid;

    IF v_att_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM employee_education_attachments
      WHERE id = v_att_id AND education_id = v_edu_id
    ) THEN
      -- Update existing row — only document_type can change
      UPDATE employee_education_attachments SET
        document_type = COALESCE(NULLIF(v_att->>'document_type', ''), document_type)
      WHERE id = v_att_id AND education_id = v_edu_id;
    ELSE
      -- Insert new attachment
      INSERT INTO employee_education_attachments (
        education_id, employee_id,
        document_type, file_name, original_file_name,
        file_path, mime_type, file_size,
        uploaded_by, created_by
      ) VALUES (
        v_edu_id, p_employee_id,
        NULLIF(v_att->>'document_type',      ''),
        NULLIF(v_att->>'file_name',          ''),
        COALESCE(NULLIF(v_att->>'original_file_name', ''), NULLIF(v_att->>'file_name', '')),
        NULLIF(v_att->>'file_path',          ''),
        COALESCE(NULLIF(v_att->>'mime_type', ''), 'application/octet-stream'),
        COALESCE(NULLIF(v_att->>'file_size', '')::bigint, 0),
        v_actor, v_actor
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'workflow', false, 'education_id', v_edu_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid, boolean) TO authenticated;

COMMENT ON FUNCTION upsert_education IS
  'Mig 662: Path A/B workflow gate; p_force_path_a for trigger calls; p_subject_employee_id fix. '
  'Mig 680: fixed attachment loop — doc_type → document_type; removed non-existent updated_at; '
  'added missing NOT NULL columns (original_file_name, mime_type, file_size); '
  'soft-delete via _removed → is_active = false.';
