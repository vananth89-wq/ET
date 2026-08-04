-- =============================================================================
-- Migration 715 — Restore remove_education permission clause to mig 665 pattern
--
-- REASON FOR THIS MIGRATION
-- ═════════════════════════
-- Mig 693 added `p_comment` to remove_education (correctly, for the
-- WorkflowSubmitModal justification text). While doing so the access-check
-- clause at the top of the function was inadvertently changed from
--   delete OR edit  (mig 665 pattern)
-- to
--   delete OR view  (mig 693, current)
--
-- Two problems this created, both currently live:
--
--   1. BROKEN — users holding `education.edit` (but not `delete`) can no
--      longer soft-delete. Edit-implies-delete is the standard CRUD pattern
--      elsewhere in the codebase; this function was the outlier.
--
--   2. SECURITY REGRESSION — users with only `education.view` scoped to
--      the employee can now delete rows. Read permission must never grant
--      destructive access.
--
-- APPROACH — STRICTLY INCREMENTAL
-- ═══════════════════════════════
-- Re-issue remove_education with mig 693's body VERBATIM, changing ONLY
-- the access-check clause back to mig 665's pattern:
--
--     user_can('education','delete', p_employee_id)
--  OR user_can('education','delete', NULL)
--  OR user_can('education','edit',   p_employee_id)
--  OR user_can('education','edit',   NULL)
--
-- Everything else — p_comment parameter, signature, Path A/B logic,
-- workflow routing, submit_change_request call, direct soft-delete, error
-- messages — is byte-for-byte identical to mig 693.
--
-- Safe to run multiple times (CREATE OR REPLACE).
-- Supersedes: mig 693 (remove_education portion only — upsert_education
-- from 693 is left untouched).
-- =============================================================================

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
  -- Access check — mig 715: restored mig 665 pattern
  -- (delete OR edit, both scoped and NULL). Mig 693 had inadvertently
  -- replaced `edit`-branches with a single `view` branch — both a
  -- functional break (edit-holders locked out) and a security regression
  -- (view-holders could delete).
  IF NOT (
    user_can('education', 'delete', p_employee_id)
    OR user_can('education', 'delete', NULL)
    OR user_can('education', 'edit',   p_employee_id)
    OR user_can('education', 'edit',   NULL)
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
  'Mig 665/693/715: Path A/B workflow gate for education removal. '
  'Mig 693: merged p_force_path_a with p_comment for WorkflowSubmitModal. '
  'Mig 715: restored access clause to mig 665 pattern (delete OR edit, '
  'both scoped and NULL). Mig 693 had accidentally swapped edit->view — '
  'a break for edit-holders and a security hole for view-holders.';


-- ── Verification ────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE routine_schema = 'public' AND routine_name = 'remove_education'
  ) THEN RAISE EXCEPTION 'ABORT: remove_education missing.'; END IF;
  RAISE NOTICE 'Migration 715: remove_education access clause restored to delete OR edit.';
END;
$$;
