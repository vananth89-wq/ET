-- =============================================================================
-- Migration 373 — Fix get_profile_workflow_gates: exclude orphaned pending_changes
--
-- A workflow_pending_changes row with instance_id IS NULL means the change
-- request was staged but never submitted to the workflow engine. These rows
-- should not count as "pending" and must not surface the pending badge in the UI.
--
-- Add two guards to the pending_counts query:
--   1. instance_id IS NOT NULL  — must have been submitted
--   2. JOIN workflow_instances wi ON wi.status IN ('in_progress','awaiting_clarification')
--      — the workflow must still be live
-- =============================================================================

CREATE OR REPLACE FUNCTION get_profile_workflow_gates()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id  uuid := auth.uid();
  v_module_codes text[] := ARRAY[
    'profile_personal','profile_contact','profile_employment',
    'profile_address','profile_passport','profile_identification',
    'profile_emergency_contact','profile_bank','profile_dependents',
    'profile_job_relationships'
  ];
  v_code        text;
  v_template_id uuid;
  v_gated       text[]  := ARRAY[]::text[];
  v_pending     jsonb   := '{}'::jsonb;
  v_instance_ids jsonb  := '{}'::jsonb;
  v_is_bank_exception boolean := false;
BEGIN
  IF v_profile_id IS NULL THEN
    RETURN jsonb_build_object(
      'gated_modules',   '[]'::jsonb,
      'pending_counts',  '{}'::jsonb,
      'instance_ids',    '{}'::jsonb,
      'is_bank_exception', false
    );
  END IF;

  -- 1. Gated modules
  FOREACH v_code IN ARRAY v_module_codes LOOP
    v_template_id := resolve_workflow_for_submission(v_code, v_profile_id);
    IF v_template_id IS NOT NULL THEN
      v_gated := array_append(v_gated, v_code);
    END IF;
  END LOOP;

  -- 2. Pending counts — only rows with a live workflow instance
  SELECT COALESCE(jsonb_object_agg(module_code, cnt), '{}')
  INTO   v_pending
  FROM (
    SELECT wpc.module_code, COUNT(*)::int AS cnt
    FROM   workflow_pending_changes wpc
    JOIN   workflow_instances wi
           ON wi.id = wpc.instance_id
          AND wi.status IN ('in_progress', 'awaiting_clarification')
    WHERE  wpc.module_code  = ANY(v_module_codes)
      AND  wpc.status       = 'pending'
      AND  wpc.submitted_by = v_profile_id
      AND  wpc.instance_id  IS NOT NULL
    GROUP  BY wpc.module_code
  ) sub;

  -- 3. Instance IDs for the "View approval progress" link
  SELECT COALESCE(jsonb_object_agg(module_code, instance_id), '{}')
  INTO   v_instance_ids
  FROM (
    SELECT DISTINCT ON (wpc.module_code)
           wpc.module_code,
           wpc.instance_id::text
    FROM   workflow_pending_changes wpc
    JOIN   workflow_instances wi
           ON wi.id = wpc.instance_id
          AND wi.status IN ('in_progress', 'awaiting_clarification')
    WHERE  wpc.module_code  = ANY(v_module_codes)
      AND  wpc.status       = 'pending'
      AND  wpc.submitted_by = v_profile_id
      AND  wpc.instance_id  IS NOT NULL
    ORDER  BY wpc.module_code, wpc.created_at DESC
  ) sub;

  -- 4. Bank exception flag
  SELECT EXISTS (
    SELECT 1
    FROM   user_roles ur
    JOIN   roles r ON r.id = ur.role_id
    WHERE  ur.profile_id = v_profile_id
      AND  ur.is_active  = true
      AND  r.code IN ('bank_exceptions', 'admin', 'hr', 'hr_admin', 'system_admin')
  ) INTO v_is_bank_exception;

  RETURN jsonb_build_object(
    'gated_modules',     to_jsonb(v_gated),
    'pending_counts',    v_pending,
    'instance_ids',      v_instance_ids,
    'is_bank_exception', v_is_bank_exception
  );
END;
$$;

COMMENT ON FUNCTION get_profile_workflow_gates() IS
  'Mig 373: pending_counts now only includes rows with a live workflow instance '
  '(in_progress / awaiting_clarification) and a non-null instance_id. '
  'Orphaned pending_changes (instance_id IS NULL or instance resolved) no longer '
  'surface the pending badge in MyProfile.';
