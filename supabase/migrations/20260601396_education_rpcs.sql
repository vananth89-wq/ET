-- =============================================================================
-- Migration 396 — Education Module: RPCs
--
-- Four SECURITY DEFINER functions:
--
--   upsert_education(p_employee_id, p_education_data, p_education_id?)
--     Dual-path. PATH A: direct write (HR/admin, hire pipeline).
--     PATH B: workflow staging via submit_change_request.
--     Handles highest-qualification atomic swap and attachment upsert.
--     Returns { ok, workflow, education_id } or { ok, workflow, instance_id, pending_change_id }.
--
--   remove_education(p_employee_id, p_education_id)
--     Soft-delete (is_active=false). Dual-path.
--
--   get_employee_education(p_employee_id, p_include_inactive?)
--     Returns active records with attachments, ordered by:
--     is_highest_qualification DESC, end_date DESC NULLS FIRST, start_date DESC.
--
--   get_employee_education_history(p_employee_id)
--     Same as get_employee_education but includes soft-deleted rows.
--     Gated on education.history OR education.view.
--
-- Design spec: docs/education-design.md §4
-- Predecessor: mig 395 (schema)
-- Next: mig 397 (workflow branches)
-- =============================================================================


-- =============================================================================
-- 1. upsert_education
-- =============================================================================

DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid);

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid DEFAULT NULL
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
  v_edu_id             uuid;
  v_education_level    text;
  v_degree             text;
  v_institution        text;
  v_field_of_study     text;
  v_start_date         date;
  v_end_date           date;
  v_completion_status  text;
  v_grade_or_gpa       text;
  v_is_highest         boolean;
  v_att                jsonb;
  v_att_id             uuid;
  v_instance_id        uuid;
  v_pending_id         uuid;
  v_submit_result      jsonb;
BEGIN

  -- ── Path resolution ─────────────────────────────────────────────────────────
  -- PATH A: direct write permission on this employee OR hire-pipeline
  -- PATH B: scoped view-only (ESS) — route through workflow
  v_is_path_a := (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR (
      -- hire pipeline: HR with view permission + employee is pre-hire
      user_can('education', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  );

  IF NOT v_is_path_a AND NOT user_can('education', 'view', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- ── Extract fields ───────────────────────────────────────────────────────────
  v_education_level   := p_education_data->>'education_level';
  v_degree            := NULLIF(trim(p_education_data->>'degree'),       '');
  v_institution       := NULLIF(trim(p_education_data->>'institution'),  '');
  v_field_of_study    := NULLIF(trim(p_education_data->>'field_of_study'), '');
  v_start_date        := NULLIF(p_education_data->>'start_date', '')::date;
  v_end_date          := NULLIF(p_education_data->>'end_date',   '')::date;
  v_completion_status := p_education_data->>'completion_status';
  v_grade_or_gpa      := NULLIF(trim(p_education_data->>'grade_or_gpa'), '');
  v_is_highest        := COALESCE((p_education_data->>'is_highest_qualification')::boolean, false);

  -- ── Mandatory field checks ───────────────────────────────────────────────────
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
      p_module_code   => 'profile_education',
      p_record_id     => p_education_id,
      p_proposed_data => p_education_data,
      p_action        => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',               true,
      'workflow',         true,
      'instance_id',      v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- ── PATH A: direct write ─────────────────────────────────────────────────────

  -- Atomic swap: untick any existing highest qualification before setting new one
  IF v_is_highest THEN
    UPDATE employee_education
    SET    is_highest_qualification = false,
           updated_by               = v_actor,
           updated_at               = NOW()
    WHERE  employee_id              = p_employee_id
      AND  is_highest_qualification = true
      AND  is_active                = true
      AND  (p_education_id IS NULL OR id <> p_education_id);
  END IF;

  IF p_education_id IS NOT NULL THEN
    -- ── UPDATE existing record ─────────────────────────────────────────────────
    UPDATE employee_education
    SET
      education_level          = v_education_level,
      degree                   = v_degree,
      institution              = v_institution,
      field_of_study           = v_field_of_study,
      start_date               = v_start_date,
      end_date                 = v_end_date,
      completion_status        = v_completion_status,
      grade_or_gpa             = v_grade_or_gpa,
      is_highest_qualification = v_is_highest,
      updated_by               = v_actor,
      updated_at               = NOW()
    WHERE id          = p_education_id
      AND employee_id = p_employee_id
      AND is_active   = true;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already removed.');
    END IF;

    v_edu_id := p_education_id;

  ELSE
    -- ── INSERT new record ──────────────────────────────────────────────────────
    INSERT INTO employee_education (
      employee_id, education_level, degree, institution, field_of_study,
      start_date, end_date, completion_status, grade_or_gpa,
      is_highest_qualification, created_by, updated_by
    ) VALUES (
      p_employee_id, v_education_level, v_degree, v_institution, v_field_of_study,
      v_start_date, v_end_date, v_completion_status, v_grade_or_gpa,
      v_is_highest, v_actor, v_actor
    )
    RETURNING id INTO v_edu_id;
  END IF;

  -- ── Attachments ──────────────────────────────────────────────────────────────
  IF p_education_data ? 'attachments' THEN
    FOR v_att IN SELECT * FROM jsonb_array_elements(p_education_data->'attachments')
    LOOP
      -- Soft-remove flagged attachments
      IF (v_att->>'_removed')::boolean IS TRUE AND (v_att->>'id') IS NOT NULL THEN
        UPDATE employee_education_attachments
        SET    is_active = false
        WHERE  id          = (v_att->>'id')::uuid
          AND  education_id = v_edu_id;
        CONTINUE;
      END IF;

      -- Skip already-saved attachments (have an id, not removed)
      IF (v_att->>'id') IS NOT NULL AND (v_att->>'_removed') IS DISTINCT FROM 'true' THEN
        -- Update document_type if changed
        UPDATE employee_education_attachments
        SET    document_type = COALESCE(v_att->>'document_type', document_type)
        WHERE  id            = (v_att->>'id')::uuid
          AND  education_id  = v_edu_id;
        CONTINUE;
      END IF;

      -- New attachment — must have a file_path (uploaded before RPC call)
      IF NULLIF(v_att->>'file_path', '') IS NULL THEN
        CONTINUE; -- skip staged-only entries without a real path
      END IF;

      INSERT INTO employee_education_attachments (
        education_id, employee_id, document_type,
        file_name, original_file_name, file_path,
        mime_type, file_size, uploaded_by, created_by
      ) VALUES (
        v_edu_id,
        p_employee_id,
        v_att->>'document_type',
        v_att->>'file_name',
        COALESCE(v_att->>'original_file_name', v_att->>'file_name'),
        v_att->>'file_path',
        COALESCE(v_att->>'mime_type', 'application/octet-stream'),
        COALESCE((v_att->>'file_size')::bigint, 0),
        v_actor,
        v_actor
      );
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'workflow',    false,
    'education_id', v_edu_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_education(uuid, jsonb, uuid) IS
  'Add or edit a single employee_education row. '
  'PATH A (direct): HR / admin / hire pipeline — writes immediately. '
  'PATH B (workflow): ESS scoped-only permission — stages via submit_change_request. '
  'Handles highest-qualification atomic swap and attachment upsert/soft-remove. '
  'Mig 396.';

REVOKE ALL     ON FUNCTION upsert_education(uuid, jsonb, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid) TO authenticated;


-- =============================================================================
-- 2. remove_education
-- =============================================================================

DROP FUNCTION IF EXISTS remove_education(uuid, uuid);

CREATE OR REPLACE FUNCTION remove_education(
  p_employee_id  uuid,
  p_education_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor       uuid    := auth.uid();
  v_is_path_a   boolean;
  v_submit_result jsonb;
BEGIN

  v_is_path_a := (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
  );

  IF NOT v_is_path_a AND NOT user_can('education', 'view', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- PATH B: stage removal via workflow
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code   => 'profile_education',
      p_record_id     => p_education_id,
      p_proposed_data => jsonb_build_object(
        '_operation',   'remove',
        'education_id', p_education_id
      ),
      p_action        => 'delete'
    );

    IF NOT (v_submit_result->>'ok')::boolean THEN
      RETURN v_submit_result;
    END IF;

    RETURN jsonb_build_object(
      'ok',               true,
      'workflow',         true,
      'instance_id',      v_submit_result->'instance_id',
      'pending_change_id', v_submit_result->'pending_id'
    );
  END IF;

  -- PATH A: direct soft-delete
  UPDATE employee_education
  SET
    is_active   = false,
    inactive_at = NOW(),
    inactive_by = v_actor,
    updated_by  = v_actor,
    updated_at  = NOW()
  WHERE id          = p_education_id
    AND employee_id = p_employee_id
    AND is_active   = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already removed.');
  END IF;

  -- Cascade soft-delete to attachments
  UPDATE employee_education_attachments
  SET    is_active = false
  WHERE  education_id = p_education_id
    AND  is_active    = true;

  RETURN jsonb_build_object('ok', true, 'workflow', false);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION remove_education(uuid, uuid) IS
  'Soft-delete a single employee_education row and its attachments. '
  'PATH A: direct write. PATH B: workflow staging for ESS. Mig 396.';

REVOKE ALL     ON FUNCTION remove_education(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION remove_education(uuid, uuid) TO authenticated;


-- =============================================================================
-- 3. get_employee_education
-- =============================================================================

DROP FUNCTION IF EXISTS get_employee_education(uuid, boolean);

CREATE OR REPLACE FUNCTION get_employee_education(
  p_employee_id      uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (
    user_can('education', 'view', p_employee_id)
    OR user_can('education', 'view', NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  SELECT jsonb_build_object(
    'ok',        true,
    'education', COALESCE(jsonb_agg(row_data ORDER BY
      row_data->>'is_highest_qualification' DESC,
      row_data->>'end_date'   DESC NULLS FIRST,
      row_data->>'start_date' DESC
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      to_jsonb(ee.*) ||
      jsonb_build_object(
        'attachments', COALESCE((
          SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.uploaded_at)
          FROM   employee_education_attachments a
          WHERE  a.education_id = ee.id
            AND  a.is_active    = true
        ), '[]'::jsonb)
      ) AS row_data
    FROM employee_education ee
    WHERE ee.employee_id = p_employee_id
      AND (p_include_inactive OR ee.is_active = true)
  ) sub;

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION get_employee_education(uuid, boolean) IS
  'Returns all education records for an employee with embedded attachments. '
  'Sort: highest qualification first, then end_date DESC, start_date DESC. '
  'Pass p_include_inactive=true to include soft-deleted rows. Mig 396.';

REVOKE ALL     ON FUNCTION get_employee_education(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_education(uuid, boolean) TO authenticated;


-- =============================================================================
-- 4. get_employee_education_history
-- =============================================================================

DROP FUNCTION IF EXISTS get_employee_education_history(uuid);

CREATE OR REPLACE FUNCTION get_employee_education_history(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Requires history OR view permission
  IF NOT (
    user_can('education', 'history', p_employee_id)
    OR user_can('education', 'history', NULL)
    OR user_can('education', 'view',    p_employee_id)
    OR user_can('education', 'view',    NULL)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  RETURN get_employee_education(p_employee_id, true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION get_employee_education_history(uuid) IS
  'Returns all education records including soft-deleted. '
  'Delegates to get_employee_education(p_employee_id, true). '
  'Requires education.history OR education.view. Mig 396.';

REVOKE ALL     ON FUNCTION get_employee_education_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_education_history(uuid) TO authenticated;


-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT proname, prosecdef AS security_definer
FROM   pg_proc
WHERE  proname IN (
  'upsert_education', 'remove_education',
  'get_employee_education', 'get_employee_education_history'
)
ORDER  BY proname;

-- =============================================================================
-- END OF MIGRATION 396
-- =============================================================================
