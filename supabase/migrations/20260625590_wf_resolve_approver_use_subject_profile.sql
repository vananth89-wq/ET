-- =============================================================================
-- Migration 590: wf_resolve_approver — use subject_profile_id for MANAGER/DEPT_HEAD
--
-- Bug: wf_resolve_approver resolves MANAGER and DEPT_HEAD approvers by walking
-- v_instance.submitted_by → employee → manager_id.
-- For admin-submitted workflows (e.g. termination), submitted_by is the HR admin
-- (Vijey) who has no manager → resolver returns NULL → step auto-skipped →
-- wf_submit early-returns without writing the 'submitted' action log entry →
-- submitter's comment is lost.
--
-- Fix: for MANAGER and DEPT_HEAD steps, resolve from subject_profile_id instead
-- of submitted_by. subject_profile_id is stamped by wf_submit (mig 528) to the
-- subject employee's active profile (Abdul Malik's profile for HR-initiated
-- terminations). For self-service, subject_profile_id = submitted_by, so
-- behaviour is unchanged.
--
-- DEPT_HEAD fix: was using v_submitter_emp.dept_id (admin's dept). Now uses
-- the subject employee's dept_id.
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
  v_step             RECORD;
  v_instance         RECORD;
  v_submitter_emp    RECORD;
  v_subject_emp      RECORD;
  v_approver         uuid;
  -- Chain delegation variables
  v_chain_depth      integer := 0;
  v_chain_max        CONSTANT integer := 5;
  v_next_delegate    uuid;
BEGIN
  -- ── Load step ──────────────────────────────────────────────────────────────
  SELECT approver_type, approver_role, approver_profile_id,
         template_id, allow_delegation
  INTO   v_step
  FROM   workflow_steps
  WHERE  id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: step % not found', p_step_id;
  END IF;

  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT submitted_by, metadata, module_code, subject_profile_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: instance % not found', p_instance_id;
  END IF;

  -- ── Submitter employee record (for SELF / ROLE dedup) ─────────────────────
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_submitter_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_instance.submitted_by;

  -- ── Subject employee record (for MANAGER / DEPT_HEAD) ─────────────────────
  -- subject_profile_id = subject employee's profile (mig 528).
  -- For self-service: subject_profile_id = submitted_by → same as submitter.
  -- For admin-on-behalf: subject_profile_id = subject employee's profile.
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_subject_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by);

  -- ── Resolve by approver type ───────────────────────────────────────────────

  CASE v_step.approver_type

    WHEN 'MANAGER' THEN
      -- Walk SUBJECT employee → manager (not submitter → manager)
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_subject_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    WHEN 'ROLE' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      WHERE  r.code      = v_step.approver_role
        AND  ur.is_active = true
        AND  ur.profile_id != v_instance.submitted_by
      LIMIT  1;

    WHEN 'DEPT_HEAD' THEN
      -- Walk SUBJECT employee → dept_id → dept head (not submitter's dept)
      SELECT p.id INTO v_approver
      FROM   department_heads dh
      JOIN   employees dh_emp ON dh_emp.id = dh.employee_id
      JOIN   profiles  p      ON p.employee_id = dh_emp.id AND p.is_active = true
      WHERE  dh.department_id = v_subject_emp.dept_id
        AND  (dh.to_date IS NULL OR dh.to_date >= CURRENT_DATE)
      LIMIT  1;

    WHEN 'SPECIFIC_USER' THEN
      v_approver := v_step.approver_profile_id;

    WHEN 'SELF' THEN
      -- Always route to the submitter; delegation never applies.
      v_approver := v_instance.submitted_by;
      RETURN v_approver;

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
        WHERE  p.employee_id = v_subject_emp.manager_id
          AND  p.is_active   = true
        LIMIT  1;
      END IF;

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation chain ─────────────────────────────────────────────────
  IF v_approver IS NOT NULL AND v_step.allow_delegation = true THEN
    LOOP
      v_chain_depth := v_chain_depth + 1;
      EXIT WHEN v_chain_depth > v_chain_max;

      SELECT delegate_id INTO v_next_delegate
      FROM   workflow_delegations
      WHERE  delegator_id = v_approver
        AND  is_active    = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_step.template_id)
      LIMIT  1;

      EXIT WHEN v_next_delegate IS NULL;

      v_approver := v_next_delegate;
    END LOOP;
  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver(uuid, uuid) IS
  'Mig 590: MANAGER/DEPT_HEAD now resolve via subject_profile_id (not submitted_by). '
  'Fixes admin-submitted workflows where submitter has no manager — previously '
  'caused auto-skip of the manager step and lost the submitter comment. '
  'subject_profile_id = submitted_by for self-service (unchanged). '
  'Delegation chain up to 5 hops still applied.';
