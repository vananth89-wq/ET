-- =============================================================================
-- Migration 361 — Workflow: JOB_RELATIONSHIP approver type
--
-- Changes:
--   1. Add relationship_code column to workflow_steps
--   2. Extend wf_resolve_approver() with JOB_RELATIONSHIP branch
--      • Reads the submitter's matrix manager for the given code from employees
--      • NULL or Inactive manager → skip the step (RETURN NULL) + audit log entry
--      • Delegation still applied when a valid approver is resolved
--
-- Design spec: docs/job-relationships-design.md §5
-- =============================================================================


-- =============================================================================
-- 1. Add relationship_code to workflow_steps
-- =============================================================================

ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS relationship_code TEXT NULL;

COMMENT ON COLUMN workflow_steps.relationship_code IS
  'For approver_type = JOB_RELATIONSHIP: which of the 6 matrix-manager codes '
  '(PM01–OM03) to resolve for the submitter. NULL for all other approver types.';


-- =============================================================================
-- 2. Extend wf_resolve_approver with JOB_RELATIONSHIP branch
--    Full function recreated — only the CASE block gains the new branch.
--    Existing behaviour for all other types is unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_resolve_approver(
  p_step_id     uuid,
  p_instance_id uuid
) RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_step              RECORD;
  v_instance          RECORD;
  v_submitter_emp     RECORD;
  v_approver          uuid;
  v_delegate          uuid;
  -- JOB_RELATIONSHIP resolution
  v_target_emp_id     uuid;
  v_target_is_active  boolean;
BEGIN
  SELECT approver_type, approver_role, approver_profile_id, template_id, relationship_code
  INTO   v_step
  FROM   workflow_steps
  WHERE  id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: step % not found', p_step_id;
  END IF;

  SELECT submitted_by, metadata, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: instance % not found', p_instance_id;
  END IF;

  -- Submitter's employee record
  SELECT e.id, e.manager_id, e.dept_id,
         e.pm01_manager_id, e.pm02_manager_id, e.pm03_manager_id,
         e.om01_manager_id, e.om02_manager_id, e.om03_manager_id
  INTO   v_submitter_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_instance.submitted_by;

  -- ── Resolve by type ──────────────────────────────────────────────────────

  CASE v_step.approver_type

    WHEN 'MANAGER' THEN
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_submitter_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    WHEN 'ROLE' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id AND r.code = v_step.approver_role
      WHERE  ur.is_active   = true
        AND  ur.profile_id != v_instance.submitted_by
      LIMIT  1;

    WHEN 'DEPT_HEAD' THEN
      SELECT p.id INTO v_approver
      FROM   department_heads dh
      JOIN   employees dh_emp ON dh_emp.id = dh.employee_id
      JOIN   profiles  p      ON p.employee_id = dh_emp.id AND p.is_active = true
      WHERE  dh.department_id = v_submitter_emp.dept_id
        AND  (dh.to_date IS NULL OR dh.to_date >= CURRENT_DATE)
      LIMIT  1;

    WHEN 'SPECIFIC_USER' THEN
      v_approver := v_step.approver_profile_id;

    WHEN 'SELF' THEN
      v_approver := v_instance.submitted_by;

    WHEN 'RULE_BASED' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      JOIN   workflow_step_conditions wsc
               ON wsc.step_id = p_step_id AND wsc.skip_step = false
      WHERE  r.code = wsc.value
        AND  ur.is_active = true
        AND  ur.profile_id != v_instance.submitted_by
      LIMIT  1;

      IF v_approver IS NULL THEN
        SELECT p.id INTO v_approver
        FROM   profiles p
        WHERE  p.employee_id = v_submitter_emp.manager_id
          AND  p.is_active   = true
        LIMIT  1;
      END IF;

    WHEN 'JOB_RELATIONSHIP' THEN
      -- Resolve the submitter's matrix manager for the given relationship_code
      v_target_emp_id := CASE v_step.relationship_code
        WHEN 'PM01' THEN v_submitter_emp.pm01_manager_id
        WHEN 'PM02' THEN v_submitter_emp.pm02_manager_id
        WHEN 'PM03' THEN v_submitter_emp.pm03_manager_id
        WHEN 'OM01' THEN v_submitter_emp.om01_manager_id
        WHEN 'OM02' THEN v_submitter_emp.om02_manager_id
        WHEN 'OM03' THEN v_submitter_emp.om03_manager_id
        ELSE NULL
      END;

      IF v_target_emp_id IS NULL THEN
        -- No matrix manager assigned for this code — skip step silently
        INSERT INTO workflow_action_log (
          instance_id, actor_id, action, notes
        ) VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format(
            'JOB_RELATIONSHIP step skipped: %s unassigned for submitter (profile=%s)',
            v_step.relationship_code,
            v_instance.submitted_by
          )
        );
        RETURN NULL;
      END IF;

      -- Check Active status at read time (not cached — fresh lookup)
      SELECT (status = 'Active') INTO v_target_is_active
      FROM   employees
      WHERE  id = v_target_emp_id;

      IF NOT FOUND OR NOT v_target_is_active THEN
        -- Matrix manager exists but is Inactive — skip step silently
        INSERT INTO workflow_action_log (
          instance_id, actor_id, action, notes
        ) VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format(
            'JOB_RELATIONSHIP step skipped: %s manager (employee=%s) is inactive or not found for submitter (profile=%s)',
            v_step.relationship_code,
            v_target_emp_id,
            v_instance.submitted_by
          )
        );
        RETURN NULL;
      END IF;

      -- Resolve to profile_id
      SELECT id INTO v_approver
      FROM   profiles
      WHERE  employee_id = v_target_emp_id
        AND  is_active   = true
      LIMIT  1;

      IF v_approver IS NULL THEN
        -- Active employee but no active profile (edge case) — skip
        INSERT INTO workflow_action_log (
          instance_id, actor_id, action, notes
        ) VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format(
            'JOB_RELATIONSHIP step skipped: %s manager (employee=%s) has no active profile',
            v_step.relationship_code,
            v_target_emp_id
          )
        );
        RETURN NULL;
      END IF;

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation ──────────────────────────────────────────────────────
  -- Skip delegation for SELF steps and NULL results (already-skipped JOB_RELATIONSHIP)
  IF v_approver IS NOT NULL AND v_step.approver_type NOT IN ('SELF', 'JOB_RELATIONSHIP') THEN
    SELECT delegate_id INTO v_delegate
    FROM   workflow_delegations
    WHERE  delegator_id  = v_approver
      AND  is_active     = true
      AND  CURRENT_DATE BETWEEN from_date AND to_date
      AND  (template_id IS NULL OR template_id = v_step.template_id)
    LIMIT  1;

    IF v_delegate IS NOT NULL THEN
      v_approver := v_delegate;
    END IF;
  ELSIF v_approver IS NOT NULL AND v_step.approver_type = 'JOB_RELATIONSHIP' THEN
    -- Delegation IS applied to JOB_RELATIONSHIP approvers (matrix manager may delegate)
    SELECT delegate_id INTO v_delegate
    FROM   workflow_delegations
    WHERE  delegator_id  = v_approver
      AND  is_active     = true
      AND  CURRENT_DATE BETWEEN from_date AND to_date
      AND  (template_id IS NULL OR template_id = v_step.template_id)
    LIMIT  1;

    IF v_delegate IS NOT NULL THEN
      v_approver := v_delegate;
    END IF;
  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver(uuid, uuid) IS
  'Resolves the profile_id of the approver for a step in a given instance. '
  'Types: MANAGER, ROLE, DEPT_HEAD, SPECIFIC_USER, SELF, RULE_BASED, JOB_RELATIONSHIP. '
  'JOB_RELATIONSHIP: reads submitter''s matrix manager (pm01–om03) from employees mirror; '
  'skips step (RETURN NULL + workflow_action_log) if unassigned or Inactive. '
  'Applies active delegation rules (except SELF steps). '
  'Returns NULL if no approver is found.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm relationship_code column exists
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'workflow_steps'
  AND  column_name  = 'relationship_code';

-- Confirm wf_resolve_approver handles JOB_RELATIONSHIP
SELECT proname,
       prosrc LIKE '%JOB_RELATIONSHIP%' AS has_jr_type
FROM   pg_proc
WHERE  proname = 'wf_resolve_approver';

-- =============================================================================
-- END OF MIGRATION 361
-- =============================================================================
