-- =============================================================================
-- Migration 692 — upsert_education / remove_education: accept p_comment
--
-- CONTEXT
-- ═══════
-- Address / Personal / Contact / Employment sections show a
-- WorkflowSubmitModal preview before submit (routing chain + comment field)
-- because they call submit_change_request directly, which accepts p_comment.
--
-- Education uses upsert_education / remove_education wrappers that internally
-- decide Path A (direct) vs Path B (workflow). The Path B branch calls
-- submit_change_request WITHOUT a comment — so the comment field is unusable
-- for Education even if we add the modal on the frontend.
--
-- FIX
-- ═══
-- Add an optional p_comment parameter to both education RPCs and thread it
-- through to submit_change_request in the Path B branch. No behaviour change
-- for existing callers (comment defaults to NULL).
--
-- IDEMPOTENT — DROP + CREATE, same GRANTs as mig 396.
-- =============================================================================


-- ── 1. upsert_education ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid);
DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid, text);

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid DEFAULT NULL,
  p_comment        text DEFAULT NULL
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

  v_is_path_a := (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR (
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

  -- Extract + validate (unchanged from mig 396)
  v_education_level   := p_education_data->>'education_level';
  v_degree            := NULLIF(trim(p_education_data->>'degree'),       '');
  v_institution       := NULLIF(trim(p_education_data->>'institution'),  '');
  v_field_of_study    := NULLIF(trim(p_education_data->>'field_of_study'), '');
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

  -- ── PATH B: stage via workflow — NOW threads comment through ────────────
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code   => 'profile_education',
      p_record_id     => p_education_id,
      p_proposed_data => p_education_data,
      p_action        => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END,
      p_comment       => NULLIF(trim(COALESCE(p_comment, '')), '')
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

  -- ── PATH A: direct write (unchanged) ─────────────────────────────────────
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

  -- Attachments (unchanged from mig 396)
  IF p_education_data ? 'attachments' THEN
    FOR v_att IN SELECT * FROM jsonb_array_elements(p_education_data->'attachments')
    LOOP
      IF (v_att->>'_removed')::boolean IS TRUE AND (v_att->>'id') IS NOT NULL THEN
        UPDATE employee_education_attachments
        SET    is_active = false, updated_by = v_actor, updated_at = NOW()
        WHERE  id = (v_att->>'id')::uuid
          AND  education_id = v_edu_id;
      ELSIF v_att->>'id' IS NULL THEN
        INSERT INTO employee_education_attachments (
          education_id, file_name, file_path, file_size, mime_type, created_by, updated_by
        )
        VALUES (
          v_edu_id,
          v_att->>'file_name',
          v_att->>'file_path',
          (v_att->>'file_size')::bigint,
          v_att->>'mime_type',
          v_actor, v_actor
        )
        RETURNING id INTO v_att_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'workflow',     false,
    'education_id', v_edu_id
  );
END;
$$;

COMMENT ON FUNCTION upsert_education(uuid, jsonb, uuid, text) IS
  'Add or edit a single employee_education row. '
  'PATH A (direct): HR / admin / hire pipeline — writes immediately. '
  'PATH B (workflow): ESS scoped-only permission — stages via submit_change_request. '
  'Mig 692 adds p_comment param, threaded through to submit_change_request for Path B.';

REVOKE ALL     ON FUNCTION upsert_education(uuid, jsonb, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid, text) TO authenticated;


-- ── 2. remove_education ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS remove_education(uuid, uuid);
DROP FUNCTION IF EXISTS remove_education(uuid, uuid, text);

CREATE OR REPLACE FUNCTION remove_education(
  p_employee_id  uuid,
  p_education_id uuid,
  p_comment      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor         uuid := auth.uid();
  v_is_path_a     boolean;
  v_submit_result jsonb;
BEGIN

  v_is_path_a := (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
  );

  IF NOT v_is_path_a AND NOT user_can('education', 'view', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- PATH B: stage removal via workflow — NOW threads comment
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code   => 'profile_education',
      p_record_id     => p_education_id,
      p_proposed_data => jsonb_build_object(
        '_operation',   'remove',
        'education_id', p_education_id
      ),
      p_action        => 'delete',
      p_comment       => NULLIF(trim(COALESCE(p_comment, '')), '')
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

  RETURN jsonb_build_object('ok', true, 'workflow', false);
END;
$$;

COMMENT ON FUNCTION remove_education(uuid, uuid, text) IS
  'Soft-remove an employee_education row. '
  'PATH A (direct): HR / admin — soft-delete immediately. '
  'PATH B (workflow): ESS scoped-only permission — stages removal. '
  'Mig 692 adds p_comment for the workflow path.';

REVOKE ALL     ON FUNCTION remove_education(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION remove_education(uuid, uuid, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname = 'upsert_education'
      AND  pg_get_function_arguments(p.oid) LIKE '%p_comment text%'
  ) THEN
    RAISE EXCEPTION 'ABORT: upsert_education missing p_comment param';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname = 'remove_education'
      AND  pg_get_function_arguments(p.oid) LIKE '%p_comment text%'
  ) THEN
    RAISE EXCEPTION 'ABORT: remove_education missing p_comment param';
  END IF;
  RAISE NOTICE 'Migration 692 verified: upsert_education + remove_education accept p_comment.';
END $$;
