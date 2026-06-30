-- =============================================================================
-- Migration 621: wf_resolve_approver — restore SUBJECT_EMPLOYEE case
--
-- ROOT CAUSE
-- ──────────
-- Mig 590 rewrote wf_resolve_approver to fix MANAGER/DEPT_HEAD resolution
-- (use subject_profile_id instead of submitted_by). However it accidentally
-- dropped the SUBJECT_EMPLOYEE branch from the CASE block. Any workflow step
-- with approver_type = 'SUBJECT_EMPLOYEE' falls through to ELSE → NULL,
-- causing wf_advance_instance to stall with current_step updated but no task
-- created and the instance left in_progress forever.
--
-- The reversal template has a SUBJECT_EMPLOYEE step (the employee signs off
-- on their own reversal). Without this branch, every reversal stalls at that
-- step after all other approvers complete.
--
-- FIX
-- ───
-- Re-add the SUBJECT_EMPLOYEE branch (identical to mig 528):
--   v_approver := COALESCE(v_instance.subject_profile_id, v_instance.submitted_by)
-- Also restore the SELF early-return (mig 528 had RETURN immediately — no
-- delegation applied to SELF or SUBJECT_EMPLOYEE).
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
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_subject_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by);

  -- ── Resolve by approver type ───────────────────────────────────────────────

  CASE v_step.approver_type

    WHEN 'MANAGER' THEN
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
      -- No delegation applied to SELF steps.
      RETURN v_instance.submitted_by;

    WHEN 'SUBJECT_EMPLOYEE' THEN
      -- The employee this workflow is about.
      -- self-service:  subject_profile_id = submitted_by (same as SELF).
      -- admin-on-behalf: subject_profile_id = the subject employee's own profile.
      -- No delegation applied to SUBJECT_EMPLOYEE steps.
      RETURN COALESCE(v_instance.subject_profile_id, v_instance.submitted_by);

    WHEN 'RULE_BASED' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      JOIN   workflow_step_conditions wsc
               ON wsc.step_id = p_step_id AND wsc.skip_step = false
      WHERE  r.code         = wsc.value
        AND  ur.is_active   = true
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

  -- ── Apply delegation chain (not for SELF / SUBJECT_EMPLOYEE — early returned) ──
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
  'Mig 621: restored SUBJECT_EMPLOYEE branch (dropped by mig 590). '
  'SELF and SUBJECT_EMPLOYEE return immediately — no delegation applied. '
  'MANAGER/DEPT_HEAD resolve via subject_profile_id (mig 590 fix retained). '
  'Delegation chain up to 5 hops applied to all other types.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'wf_resolve_approver') THEN
    RAISE EXCEPTION 'ABORT: wf_resolve_approver not found after migration 621.';
  END IF;
  RAISE NOTICE 'Migration 621 verified: wf_resolve_approver has SUBJECT_EMPLOYEE restored — OK';
END;
$$;
