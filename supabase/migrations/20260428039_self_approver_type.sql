-- =============================================================================
-- Add SELF approver type to wf_resolve_approver()
--
-- SELF routes the workflow task back to the submitter themselves.
-- Use cases:
--   - Employee acknowledgement step ("I confirm I've read this policy")
--   - Clarification step ("Please provide additional receipts")
--   - Multi-stage forms where the employee acts at multiple points
--
-- Implementation: submitted_by is already on workflow_instances, so
-- resolution is a direct reference — no additional lookup needed.
-- Delegation is intentionally NOT applied to SELF steps (you can't
-- delegate a task back to yourself to yourself).
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
  v_step            RECORD;
  v_instance        RECORD;
  v_submitter_emp   RECORD;
  v_approver        uuid;
  v_delegate        uuid;
BEGIN
  SELECT approver_type, approver_role, approver_profile_id, template_id
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

  -- Submitter's employee record (needed for MANAGER and DEPT_HEAD resolution)
  SELECT e.id, e.manager_id, e.dept_id
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
      -- Route the task back to the person who submitted the request.
      -- No delegation applied — self-acknowledgement cannot be delegated.
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

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation ──────────────────────────────────────────────────────
  -- Skip delegation for SELF steps — the submitter must action these themselves.

  IF v_approver IS NOT NULL AND v_step.approver_type != 'SELF' THEN
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
  'Types: MANAGER, ROLE, DEPT_HEAD, SPECIFIC_USER, SELF, RULE_BASED. '
  'Applies active delegation rules (except for SELF steps). '
  'Returns NULL if no approver is found.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname,
       prosrc LIKE '%SELF%' AS has_self_type
FROM   pg_proc
WHERE  proname = 'wf_resolve_approver';
