-- =============================================================================
-- Migration 696 — upsert_job_relationship_set: accept p_comment
--
-- Extends the WorkflowSubmitModal + comment pattern (migs 693/694/695) to
-- Job Relationships. Threads p_comment to submit_change_request in the
-- Path B (workflow) branch. Path A (direct write) unchanged.
--
-- Body copied verbatim from mig 360 with only two additions:
--   1. p_comment TEXT DEFAULT NULL parameter
--   2. Comment passed to submit_change_request as the 5th arg (was NULL)
-- =============================================================================

DROP FUNCTION IF EXISTS upsert_job_relationship_set(uuid, date, jsonb);
DROP FUNCTION IF EXISTS upsert_job_relationship_set(uuid, date, jsonb, text);

CREATE OR REPLACE FUNCTION upsert_job_relationship_set(
  p_employee_id    uuid,
  p_effective_from date,
  p_items          jsonb,
  p_comment        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_profile  uuid;
  v_caller_emp_id   uuid;
  v_is_hr           boolean;
  v_employee        employees%ROWTYPE;
  v_item            jsonb;
  v_code            text;
  v_mgr_id          uuid;
  v_seen_codes      text[] := ARRAY[]::text[];
  v_valid_codes     text[];
  v_mgr_active      boolean;
  v_template_id     uuid;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_result          jsonb;
BEGIN
  v_caller_profile := auth.uid();

  SELECT employee_id INTO v_caller_emp_id
  FROM   profiles WHERE id = v_caller_profile;

  v_is_hr := user_can('job_relationships', 'edit', NULL);

  IF NOT v_is_hr AND NOT user_can('job_relationships', 'edit', p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED',
      'message', 'You do not have permission to edit job relationships for this employee.');
  END IF;

  SELECT * INTO v_employee FROM employees WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'EMPLOYEE_NOT_FOUND',
      'message', 'Employee not found.');
  END IF;

  IF v_employee.status IN ('Draft', 'Incomplete', 'Pending') AND NOT v_is_hr THEN
    RETURN jsonb_build_object('ok', false, 'error', 'HIRE_PIPELINE_RESTRICTED',
      'message', 'Job relationships can only be edited by HR during onboarding.');
  END IF;

  SELECT ARRAY_AGG(pv.ref_id) INTO v_valid_codes
  FROM   picklist_values pv
  JOIN   picklists pl ON pl.id = pv.picklist_id
  WHERE  pl.picklist_id = 'JOB_RELATIONSHIP_TYPE'
    AND  pv.active = true;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_code   := v_item->>'relationship_code';
    v_mgr_id := (v_item->>'manager_employee_id')::uuid;

    IF v_code IS NULL OR NOT (v_code = ANY(v_valid_codes)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CODE',
        'message', format('relationship_code %L is not a valid active JOB_RELATIONSHIP_TYPE code.', v_code));
    END IF;

    IF v_code = ANY(v_seen_codes) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'DUPLICATE_CODE',
        'message', format('Duplicate relationship_code %L in p_items.', v_code));
    END IF;
    v_seen_codes := v_seen_codes || v_code;

    IF v_mgr_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MISSING_MANAGER',
        'message', format('manager_employee_id is required for code %L.', v_code));
    END IF;

    IF v_mgr_id = p_employee_id THEN
      RETURN jsonb_build_object('ok', false, 'error', 'SELF_ASSIGNMENT',
        'message', format('Cannot assign employee as their own %L matrix manager.', v_code));
    END IF;

    SELECT (status = 'Active') INTO v_mgr_active
    FROM   employees WHERE id = v_mgr_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MANAGER_NOT_FOUND',
        'message', format('Manager employee %L not found for code %L.', v_mgr_id, v_code));
    END IF;

    IF NOT v_mgr_active THEN
      RETURN jsonb_build_object('ok', false, 'error', 'MANAGER_INACTIVE',
        'message', format('Manager for code %L must have status=Active at assignment time.', v_code));
    END IF;
  END LOOP;

  SELECT id INTO v_template_id
  FROM   workflow_templates
  WHERE  module_code = 'profile_job_relationships'
    AND  is_active   = true
  LIMIT  1;

  IF v_template_id IS NOT NULL AND NOT v_is_hr THEN
    -- MIG 696 CHANGE: thread p_comment through to submit_change_request
    SELECT submit_change_request(
      'profile_job_relationships',
      p_employee_id,
      jsonb_build_object(
        'effective_from', p_effective_from,
        'items',          p_items
      ),
      'update',
      NULLIF(trim(COALESCE(p_comment, '')), '')
    ) INTO v_result;

    RETURN v_result;
  END IF;

  SELECT fn_close_and_replace_job_relationship_set(
    p_employee_id,
    p_effective_from,
    ARRAY['PM01','PM02','PM03','OM01','OM02','OM03'],
    p_items,
    v_caller_profile
  ) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RETURN v_result;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'workflow',     false,
    'set_id',       v_result->>'set_id',
    'effective_from', p_effective_from
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'UNEXPECTED_ERROR', 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_job_relationship_set(uuid, date, jsonb, text) TO authenticated;

COMMENT ON FUNCTION upsert_job_relationship_set IS
  'Mig 360: dual-path (direct write vs workflow staging). '
  'Mig 696: p_comment param threaded to submit_change_request for WorkflowSubmitModal support.';


-- ── Verification ────────────────────────────────────────────────────────────
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_job_relationship_set';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: expected exactly 1 upsert_job_relationship_set overload, found %', v_count;
  END IF;
  RAISE NOTICE 'Migration 696 verified: upsert_job_relationship_set now accepts p_comment.';
END $$;
