-- =============================================================================
-- Migration 693 — Consolidate upsert_education / remove_education overloads
--
-- PROBLEM
-- ═══════
-- Mig 692 introduced (uuid, jsonb, uuid, text) overloads to add p_comment
-- WITHOUT dropping the existing (uuid, jsonb, uuid, boolean) overloads from
-- mig 680 (p_force_path_a). Postgres now cannot resolve 3-arg calls from
-- the frontend:
--
--   ERROR: Could not choose the best candidate function between:
--     upsert_education(p_employee_id, p_education_data, p_education_id, p_comment)
--     upsert_education(p_employee_id, p_education_data, p_education_id, p_force_path_a)
--
-- FIX
-- ═══
-- Drop BOTH conflicting overloads and create one canonical signature that
-- carries BOTH parameters:
--
--   upsert_education(p_employee_id, p_education_data, p_education_id,
--                    p_force_path_a boolean DEFAULT false,
--                    p_comment      text    DEFAULT NULL)
--
-- Same treatment for remove_education. Callers must use named arguments
-- (frontend already does via PostgREST RPC).
--
-- Preserves ALL logic from mig 680 (hire pipeline detection,
-- p_subject_employee_id passthrough, attachment loop, exception handler).
-- Only additive change: p_comment threaded into submit_change_request.
-- =============================================================================


-- ── 1. Drop all existing overloads ──────────────────────────────────────────

DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid);
DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid, boolean);
DROP FUNCTION IF EXISTS upsert_education(uuid, jsonb, uuid, text);

DROP FUNCTION IF EXISTS remove_education(uuid, uuid);
DROP FUNCTION IF EXISTS remove_education(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS remove_education(uuid, uuid, text);


-- ── 2. upsert_education — merged signature ──────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_education(
  p_employee_id    uuid,
  p_education_data jsonb,
  p_education_id   uuid    DEFAULT NULL,
  p_force_path_a   boolean DEFAULT false,   -- set true when called from trigger
  p_comment        text    DEFAULT NULL     -- workflow submission comment
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

  -- ── Access check (mig 680) ────────────────────────────────────────────────
  IF NOT (
    user_can('education', 'create', p_employee_id)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'create', NULL)
    OR user_can('education', 'edit',   NULL)
    OR user_can('education', 'view',   p_employee_id)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  -- ── Hire pipeline? ────────────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── Workflow assignment exists? ───────────────────────────────────────────
  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);

  -- ── Path resolution ──────────────────────────────────────────────────────
  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  -- ── Extract + validate fields (unchanged) ────────────────────────────────
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

  -- ── PATH B: stage via workflow — NOW threads p_comment ───────────────────
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => p_education_data,
      p_action              => CASE WHEN p_education_id IS NOT NULL THEN 'update' ELSE 'create' END,
      p_subject_employee_id => p_employee_id,
      p_comment             => NULLIF(trim(COALESCE(p_comment, '')), '')
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

  -- ── PATH A: direct write (unchanged from mig 680) ────────────────────────
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

  -- ── Attachment loop (mig 680) ────────────────────────────────────────────
  FOR v_att IN SELECT * FROM jsonb_array_elements(COALESCE(p_education_data->'attachments', '[]'::jsonb))
  LOOP
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
      UPDATE employee_education_attachments SET
        document_type = COALESCE(NULLIF(v_att->>'document_type', ''), document_type)
      WHERE id = v_att_id AND education_id = v_edu_id;
    ELSE
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

GRANT EXECUTE ON FUNCTION upsert_education(uuid, jsonb, uuid, boolean, text) TO authenticated;

COMMENT ON FUNCTION upsert_education IS
  'Mig 662/680: Path A/B workflow gate; p_force_path_a for trigger calls; '
  'attachment loop with document_type. Mig 693: merged with p_comment for '
  'WorkflowSubmitModal comment threading.';


-- ── 3. remove_education — merged signature ──────────────────────────────────

CREATE OR REPLACE FUNCTION remove_education(
  p_employee_id  uuid,
  p_education_id uuid,
  p_force_path_a boolean DEFAULT false,
  p_comment      text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor              uuid    := auth.uid();
  v_is_path_a          boolean;
  v_is_hire            boolean;
  v_has_wf_assignment  boolean;
  v_submit_result      jsonb;
BEGIN
  -- Access check
  IF NOT (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
    OR user_can('education', 'view',   p_employee_id)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM employees e
    WHERE e.id = p_employee_id AND e.status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  v_has_wf_assignment := (resolve_workflow_for_submission('profile_education', v_actor) IS NOT NULL);

  v_is_path_a := p_force_path_a OR v_is_hire OR NOT v_has_wf_assignment;

  -- PATH B: stage via workflow
  IF NOT v_is_path_a THEN
    v_submit_result := submit_change_request(
      p_module_code         => 'profile_education',
      p_record_id           => p_education_id,
      p_proposed_data       => jsonb_build_object('_operation', 'remove', 'education_id', p_education_id),
      p_action              => 'delete',
      p_subject_employee_id => p_employee_id,
      p_comment             => NULLIF(trim(COALESCE(p_comment, '')), '')
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

  -- PATH A: direct soft-delete
  UPDATE employee_education
  SET    is_active   = false,
         inactive_at = NOW(),
         inactive_by = v_actor,
         updated_by  = v_actor,
         updated_at  = NOW()
  WHERE  id = p_education_id AND employee_id = p_employee_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Education record not found or already removed.');
  END IF;

  RETURN jsonb_build_object('ok', true, 'workflow', false);
END;
$$;

GRANT EXECUTE ON FUNCTION remove_education(uuid, uuid, boolean, text) TO authenticated;

COMMENT ON FUNCTION remove_education IS
  'Mig 665/693: Path A/B workflow gate for education removal. '
  'Mig 693: merged p_force_path_a with p_comment for WorkflowSubmitModal.';


-- ── Verification ────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_upsert_count int;
  v_remove_count int;
BEGIN
  SELECT count(*) INTO v_upsert_count
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_education';

  SELECT count(*) INTO v_remove_count
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'remove_education';

  IF v_upsert_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: expected exactly 1 upsert_education overload, found %', v_upsert_count;
  END IF;
  IF v_remove_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: expected exactly 1 remove_education overload, found %', v_remove_count;
  END IF;
  RAISE NOTICE 'Migration 693 verified: single canonical overload for each education RPC.';
END $$;
