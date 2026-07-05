-- Migration 666 — Add profile_education to get_profile_workflow_gates
-- v_module_codes was missing 'profile_education', so pendingCounts and
-- gated_modules never included it — the education portlet showed no pending
-- banner and the approver inbox had no instance_id to show.

CREATE OR REPLACE FUNCTION get_profile_workflow_gates(
  p_employee_id uuid DEFAULT NULL
)
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
    'profile_job_relationships','profile_education'
  ];
  v_code         text;
  v_template_id  uuid;
  v_gated        text[]  := ARRAY[]::text[];
  v_pending      jsonb   := '{}'::jsonb;
  v_instance_ids jsonb   := '{}'::jsonb;
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

  -- 1. Gated modules — always based on the current user's workflow assignments
  FOREACH v_code IN ARRAY v_module_codes LOOP
    v_template_id := resolve_workflow_for_submission(v_code, v_profile_id);
    IF v_template_id IS NOT NULL THEN
      v_gated := array_append(v_gated, v_code);
    END IF;
  END LOOP;

  -- 2. Pending counts — scoped to the subject employee
  --    Self mode  (p_employee_id IS NULL): submitted_by = auth.uid()
  --    Employee mode (p_employee_id set):  record_id = p_employee_id
  --    For education, record_id holds the education row UUID (not employee UUID),
  --    so we also check via workflow_instances.subject_profile_id → profiles.employee_id
  SELECT COALESCE(jsonb_object_agg(module_code, cnt), '{}')
  INTO   v_pending
  FROM (
    SELECT wpc.module_code, COUNT(*)::int AS cnt
    FROM   workflow_pending_changes wpc
    JOIN   workflow_instances wi
           ON wi.id = wpc.instance_id
          AND wi.status IN ('in_progress', 'awaiting_clarification')
    LEFT JOIN profiles subj
           ON subj.id = wi.subject_profile_id
    WHERE  wpc.module_code = ANY(v_module_codes)
      AND  wpc.status      = 'pending'
      AND  wpc.instance_id IS NOT NULL
      AND  (
        CASE
          WHEN p_employee_id IS NULL THEN
            wpc.submitted_by = v_profile_id
          ELSE
            wpc.record_id    = p_employee_id
            OR subj.employee_id = p_employee_id
        END
      )
    GROUP BY wpc.module_code
  ) t;

  -- 3. Instance IDs — most recent in-progress instance per module
  SELECT COALESCE(jsonb_object_agg(module_code, instance_id), '{}')
  INTO   v_instance_ids
  FROM (
    SELECT DISTINCT ON (wpc.module_code)
           wpc.module_code,
           wpc.instance_id::text AS instance_id
    FROM   workflow_pending_changes wpc
    JOIN   workflow_instances wi
           ON wi.id = wpc.instance_id
          AND wi.status IN ('in_progress', 'awaiting_clarification')
    LEFT JOIN profiles subj
           ON subj.id = wi.subject_profile_id
    WHERE  wpc.module_code = ANY(v_module_codes)
      AND  wpc.status      = 'pending'
      AND  wpc.instance_id IS NOT NULL
      AND  (
        CASE
          WHEN p_employee_id IS NULL THEN
            wpc.submitted_by = v_profile_id
          ELSE
            wpc.record_id    = p_employee_id
            OR subj.employee_id = p_employee_id
        END
      )
    ORDER BY wpc.module_code, wpc.created_at DESC
  ) t;

  -- 4. Bank exception flag — always the current user's roles
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

GRANT EXECUTE ON FUNCTION get_profile_workflow_gates(uuid) TO authenticated;

COMMENT ON FUNCTION get_profile_workflow_gates(uuid) IS
  'Mig 507: added p_employee_id param. '
  'Mig 666: added profile_education to v_module_codes. '
  'Mig 666: pending/instance queries also match via subject_profile_id→employee_id '
  'so satellite-record modules (education, address) resolve correctly in employee mode.';
