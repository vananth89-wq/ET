-- =============================================================================
-- Migration 528 — Workflow: SUBJECT_EMPLOYEE approver type
--
-- Problem:
--   When HR Analyst submits a workflow on behalf of an employee (e.g. a change
--   request), workflow_instances.submitted_by = HR Analyst's profile.
--   There was no way for a CC (Notify Only) step to target the subject employee
--   — the person the workflow is *about* — because SELF resolves to the
--   submitter (HR Analyst), not the employee.
--
-- Solution:
--   1. Add subject_profile_id column to workflow_instances.
--      • For self-service submissions:  subject_profile_id = submitted_by.
--      • For on-behalf submissions:     subject_profile_id = subject employee's
--        active profile_id (looked up from p_subject_employee_id).
--   2. Extend workflow_steps.approver_type CHECK to include 'SUBJECT_EMPLOYEE'.
--   3. Rewrite wf_submit (based on mig 506 body + subject_profile_id stamp).
--   4. Rewrite wf_resolve_approver with SUBJECT_EMPLOYEE branch:
--      resolves to instance.subject_profile_id (falls back to submitted_by).
--      No delegation applied (same rule as SELF steps).
--
-- Backward-compatible: all existing rows backfilled to subject_profile_id =
-- submitted_by (treating historical submissions as self-service).
-- =============================================================================


-- =============================================================================
-- 1. Add subject_profile_id to workflow_instances
-- =============================================================================

ALTER TABLE workflow_instances
  ADD COLUMN IF NOT EXISTS subject_profile_id UUID
    REFERENCES profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN workflow_instances.subject_profile_id IS
  'Profile ID of the employee this workflow is about. '
  'For self-service submissions this equals submitted_by. '
  'For on-behalf submissions (HR Analyst acting for an employee) this is the '
  'subject employee''s active profile_id. '
  'Populated by wf_submit. Used by SUBJECT_EMPLOYEE approver type.';

-- Backfill existing rows: treat all historical submissions as self-service.
UPDATE workflow_instances
SET    subject_profile_id = submitted_by
WHERE  subject_profile_id IS NULL;


-- =============================================================================
-- 2. Extend approver_type CHECK on workflow_steps
-- =============================================================================

ALTER TABLE workflow_steps
  DROP CONSTRAINT IF EXISTS workflow_steps_approver_type_check;

ALTER TABLE workflow_steps
  ADD CONSTRAINT workflow_steps_approver_type_check
  CHECK (approver_type IN (
    'MANAGER',          -- submitter's line manager
    'ROLE',             -- any user with approver_role
    'DEPT_HEAD',        -- submitter's department head
    'SPECIFIC_USER',    -- fixed profile (approver_profile_id)
    'RULE_BASED',       -- evaluate workflow_step_conditions
    'SELF',             -- submitter self-approves (no delegation)
    'JOB_RELATIONSHIP', -- submitter's matrix manager (relationship_code)
    'SUBJECT_EMPLOYEE'  -- the employee the workflow is about (no delegation)
  ));

COMMENT ON COLUMN workflow_steps.approver_type IS
  'Who resolves the approver for this step. '
  'SELF = submitter; SUBJECT_EMPLOYEE = the employee the workflow is about '
  '(same as SELF for self-service, resolves to subject for on-behalf flows). '
  'No delegation applied to SELF or SUBJECT_EMPLOYEE steps.';


-- =============================================================================
-- 3. Rewrite wf_submit — mig 506 body + subject_profile_id stamp
--    Three additions vs mig 506:
--      a) DECLARE: v_subject_profile_id uuid
--      b) On-behalf block: look up subject employee's active profile
--      c) INSERT: includes subject_profile_id column
--    All other logic is identical to mig 506 (authoritative version).
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code        text,
  p_module_code          text,
  p_record_id            uuid,
  p_metadata             jsonb DEFAULT '{}',
  p_comment              text  DEFAULT NULL,
  p_subject_employee_id  uuid  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template            RECORD;
  v_first_step          RECORD;
  v_instance_id         uuid;
  v_task_id             uuid;
  v_approver_id         uuid;
  v_due_at              timestamptz;
  v_remove_reason       text;
  v_skip_reason         text;
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
  v_role_holder_id      uuid;
  v_delegate_id         uuid;
  v_tasks_created       integer := 0;
  v_guard_emp_id        uuid;
  -- mig 503: on-behalf-of stamp
  v_submitter_emp_id    uuid;
  v_actor_id_to_stamp   uuid;
  -- mig 528: subject employee profile
  v_subject_profile_id  uuid;
BEGIN
  SELECT id, version, is_active, remove_duplicate_approver, skip_duplicate_approver
  INTO   v_template
  FROM   workflow_templates
  WHERE  code      = p_template_code
    AND  is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: template % not found or inactive', p_template_code;
  END IF;

  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      = 'in_progress'
  ) THEN
    RAISE EXCEPTION 'wf_submit: an active workflow already exists for this record';
  END IF;

  -- ── Concurrent termination guard (mig 493) ────────────────────────────────
  IF p_module_code <> 'termination' THEN
    IF p_module_code = 'employee_hire' THEN
      v_guard_emp_id := p_record_id;
    ELSIF p_subject_employee_id IS NOT NULL THEN
      v_guard_emp_id := p_subject_employee_id;
    ELSE
      SELECT employee_id INTO v_guard_emp_id FROM profiles WHERE id = auth.uid();
    END IF;

    IF v_guard_emp_id IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM employee_terminations
         WHERE  employee_id    = v_guard_emp_id
           AND  workflow_status = 'PENDING'
       )
    THEN
      RAISE EXCEPTION
        'A termination is pending approval for this employee. '
        'Other workflow submissions are blocked until the termination is resolved.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- ── On-behalf-of stamp (mig 503) + subject_profile_id (mig 528) ──────────
  SELECT employee_id INTO v_submitter_emp_id FROM profiles WHERE id = auth.uid();

  IF p_subject_employee_id IS NOT NULL
     AND v_submitter_emp_id IS DISTINCT FROM p_subject_employee_id THEN
    -- HR acting on behalf of another employee
    v_actor_id_to_stamp := auth.uid();
    -- mig 528: resolve subject employee's active profile
    SELECT id INTO v_subject_profile_id
    FROM   profiles
    WHERE  employee_id = p_subject_employee_id
      AND  is_active   = true
    LIMIT  1;
  END IF;

  -- mig 528: for self-service (or if subject profile not found), subject = submitter
  IF v_subject_profile_id IS NULL THEN
    v_subject_profile_id := auth.uid();
  END IF;

  SELECT ws.*
  INTO   v_first_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_template.id
    AND  ws.is_active   = true
    AND  NOT wf_evaluate_skip_step(ws.id, p_metadata)
  ORDER  BY ws.step_order
  LIMIT  1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: no active steps found in template %', p_template_code;
  END IF;

  INSERT INTO workflow_instances
    (template_id, template_version, module_code, record_id,
     submitted_by, current_step, status, metadata,
     initiated_by_actor_id, subject_profile_id)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata,
     v_actor_id_to_stamp, v_subject_profile_id)
  RETURNING id INTO v_instance_id;

  -- ── Legacy ROLE fan-out for step 1 ────────────────────────────────────────
  IF v_first_step.approver_type = 'ROLE'
     AND v_first_step.approver_role IS NOT NULL
     AND v_first_step.approval_mode IS NULL THEN

    v_due_at := CASE
      WHEN v_first_step.is_cc     THEN NULL
      WHEN v_first_step.sla_hours IS NOT NULL
      THEN now() + (v_first_step.sla_hours * interval '1 hour')
      ELSE NULL
    END;

    FOR v_role_holder_id IN
      SELECT ur.profile_id
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      WHERE  r.code       = v_first_step.approver_role
        AND  r.active     = true
        AND  ur.is_active = true
        AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
    LOOP
      CONTINUE WHEN v_role_holder_id = auth.uid();

      SELECT delegate_id INTO v_delegate_id
      FROM   workflow_delegations
      WHERE  delegator_id = v_role_holder_id
        AND  is_active    = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_template.id)
      LIMIT  1;

      v_approver_id := COALESCE(v_delegate_id, v_role_holder_id);
      CONTINUE WHEN v_approver_id = auth.uid();

      INSERT INTO workflow_tasks
        (instance_id, step_id, step_order, assigned_to, due_at)
      VALUES
        (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, v_due_at)
      RETURNING id INTO v_task_id;

      v_tasks_created := v_tasks_created + 1;

      PERFORM wf_queue_notification(
        v_instance_id, 'wf.task_assigned', v_approver_id,
        jsonb_build_object(
          'step_name',   v_first_step.name,
          'module_code', p_module_code,
          'role_code',   v_first_step.approver_role
        )
      );
    END LOOP;

    IF v_tasks_created = 0 THEN
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes, metadata)
      VALUES
        (v_instance_id, NULL, auth.uid(), 'auto_skipped', v_first_step.step_order,
         'ROLE step auto-skipped: all active members of role ''' ||
           v_first_step.approver_role ||
           ''' are the submitter, or the role has no active members.',
         jsonb_build_object('template_code', p_template_code,
                            'role_code',     v_first_step.approver_role));

      PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
      PERFORM wf_advance_instance(v_instance_id);
      RETURN v_instance_id;
    END IF;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes, metadata)
    VALUES
      (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
       NULLIF(trim(p_comment), ''),
       jsonb_build_object('template_code', p_template_code));

    PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
    RETURN v_instance_id;
  END IF;

  -- ── Resolve approver for non-ROLE step 1 ─────────────────────────────────
  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  IF v_approver_id IS NULL THEN
    IF v_first_step.approver_type IN ('MANAGER', 'DEPT_HEAD') THEN
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes, metadata)
      VALUES
        (v_instance_id, NULL, auth.uid(), 'auto_skipped', v_first_step.step_order,
         'No ' || v_first_step.approver_type || ' found — step skipped automatically.',
         jsonb_build_object('template_code', p_template_code,
                            'approver_type', v_first_step.approver_type));

      PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
      PERFORM wf_advance_instance(v_instance_id);
      RETURN v_instance_id;
    ELSE
      RAISE EXCEPTION 'wf_submit: cannot resolve approver for step 1 of template %',
                      p_template_code;
    END IF;
  END IF;

  -- ── Removal checks ────────────────────────────────────────────────────────
  IF v_approver_id = auth.uid() THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  IF v_remove_reason IS NULL AND v_template.remove_duplicate_approver THEN
    SELECT ws2.* INTO v_lookahead_step
    FROM   workflow_steps ws2
    WHERE  ws2.template_id = v_template.id
      AND  ws2.step_order  > v_first_step.step_order
      AND  ws2.is_active   = true
      AND  NOT wf_evaluate_skip_step(ws2.id, p_metadata)
    ORDER  BY ws2.step_order LIMIT 1;

    IF FOUND THEN
      v_lookahead_approver := wf_resolve_approver(v_lookahead_step.id, v_instance_id);
      IF v_lookahead_approver IS NOT NULL AND v_lookahead_approver = v_approver_id THEN
        v_remove_reason :=
          'Step removed: same approver appears in next step (remove_duplicate_approver=true)';
      END IF;
    END IF;
  END IF;

  IF v_remove_reason IS NOT NULL THEN
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (v_instance_id, NULL, auth.uid(), 'step_removed',
       v_first_step.step_order, v_remove_reason);

    PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
    PERFORM wf_advance_instance(v_instance_id);
    RETURN v_instance_id;
  END IF;

  -- ── Skip checks ───────────────────────────────────────────────────────────
  IF v_template.skip_duplicate_approver THEN
    SELECT ws2.* INTO v_lookahead_step
    FROM   workflow_steps ws2
    WHERE  ws2.template_id = v_template.id
      AND  ws2.step_order  > v_first_step.step_order
      AND  ws2.is_active   = true
      AND  NOT wf_evaluate_skip_step(ws2.id, p_metadata)
    ORDER  BY ws2.step_order LIMIT 1;

    IF FOUND THEN
      v_lookahead_approver := wf_resolve_approver(v_lookahead_step.id, v_instance_id);
      IF v_lookahead_approver IS NOT NULL AND v_lookahead_approver = v_approver_id THEN
        v_skip_reason :=
          'Auto-skipped: same approver appears in next step (skip_duplicate_approver=true)';
      END IF;
    END IF;
  END IF;

  IF v_skip_reason IS NOT NULL THEN
    INSERT INTO workflow_tasks
      (instance_id, step_id, step_order, assigned_to, status, acted_at, notes)
    VALUES
      (v_instance_id, v_first_step.id, v_first_step.step_order,
       v_approver_id, 'skipped', now(), v_skip_reason)
    RETURNING id INTO v_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (v_instance_id, v_task_id, auth.uid(), 'skipped',
       v_first_step.step_order, v_skip_reason);

    PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
    PERFORM wf_advance_instance(v_instance_id);
    RETURN v_instance_id;
  END IF;

  -- ── Normal first step ─────────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_first_step.is_cc     THEN NULL
    WHEN v_first_step.sla_hours IS NOT NULL
    THEN now() + (v_first_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_task_id;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES
    (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
     NULLIF(trim(p_comment), ''),
     jsonb_build_object('template_code', p_template_code));

  PERFORM wf_queue_notification(
    v_instance_id, 'wf.task_assigned', v_approver_id,
    jsonb_build_object('step_name', v_first_step.name, 'module_code', p_module_code)
  );

  IF v_first_step.is_cc THEN
    UPDATE workflow_tasks
    SET status='approved', acted_at=now(), notes='CC — auto-notified'
    WHERE id = v_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (v_instance_id, v_task_id, auth.uid(), 'cc_notified',
       v_first_step.step_order, 'CC step — notification sent, auto-completed');

    PERFORM wf_advance_instance(v_instance_id);
    RETURN v_instance_id;
  END IF;

  PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb, text, uuid) IS
  'Mig 338: MANAGER/DEPT_HEAD auto-skip. '
  'Mig 480: ROLE step auto-skip when all role members are the submitter. '
  'Mig 493: concurrent termination guard. '
  'Mig 503: p_subject_employee_id stamps initiated_by_actor_id when subject ≠ actor. '
  'Mig 528: subject_profile_id populated (subject employee profile, or submitted_by for self-service).';


-- =============================================================================
-- 4. Rewrite wf_resolve_approver with SUBJECT_EMPLOYEE branch
--    Based on mig 361 body — adds SUBJECT_EMPLOYEE to the CASE block and
--    adds SUBJECT_EMPLOYEE to the no-delegation guard.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_resolve_approver(
  p_step_id     uuid,
  p_instance_id uuid
)
RETURNS uuid
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
  v_target_emp_id     uuid;
  v_target_is_active  boolean;
BEGIN
  SELECT approver_type, approver_role, approver_profile_id,
         template_id, relationship_code
  INTO   v_step
  FROM   workflow_steps
  WHERE  id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: step % not found', p_step_id;
  END IF;

  SELECT submitted_by, metadata, module_code, subject_profile_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: instance % not found', p_instance_id;
  END IF;

  -- Submitter's employee record (for MANAGER, DEPT_HEAD, JOB_RELATIONSHIP)
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

    WHEN 'SUBJECT_EMPLOYEE' THEN
      -- The employee this workflow is about.
      -- self-service: subject_profile_id = submitted_by (same as SELF).
      -- on-behalf:    subject_profile_id = the employee's own profile.
      v_approver := COALESCE(v_instance.subject_profile_id, v_instance.submitted_by);

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
        WHERE  p.employee_id = v_submitter_emp.manager_id
          AND  p.is_active   = true
        LIMIT  1;
      END IF;

    WHEN 'JOB_RELATIONSHIP' THEN
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
        INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
        VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format('JOB_RELATIONSHIP step skipped: %s unassigned for submitter (profile=%s)',
                 v_step.relationship_code, v_instance.submitted_by)
        );
        RETURN NULL;
      END IF;

      SELECT (status = 'Active') INTO v_target_is_active
      FROM   employees WHERE id = v_target_emp_id;

      IF NOT FOUND OR NOT v_target_is_active THEN
        INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
        VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format('JOB_RELATIONSHIP step skipped: %s manager (employee=%s) is inactive or not found for submitter (profile=%s)',
                 v_step.relationship_code, v_target_emp_id, v_instance.submitted_by)
        );
        RETURN NULL;
      END IF;

      SELECT id INTO v_approver
      FROM   profiles
      WHERE  employee_id = v_target_emp_id
        AND  is_active   = true
      LIMIT  1;

      IF v_approver IS NULL THEN
        INSERT INTO workflow_action_log (instance_id, actor_id, action, notes)
        VALUES (
          p_instance_id,
          COALESCE(auth.uid(), v_instance.submitted_by),
          'step_skipped',
          format('JOB_RELATIONSHIP step skipped: %s manager (employee=%s) has no active profile',
                 v_step.relationship_code, v_target_emp_id)
        );
        RETURN NULL;
      END IF;

    ELSE
      v_approver := NULL;

  END CASE;

  -- ── Apply delegation ──────────────────────────────────────────────────────
  -- No delegation for SELF, SUBJECT_EMPLOYEE, or JOB_RELATIONSHIP
  IF v_approver IS NOT NULL
     AND v_step.approver_type NOT IN ('SELF', 'SUBJECT_EMPLOYEE') THEN

    IF v_step.approver_type = 'JOB_RELATIONSHIP' THEN
      -- JOB_RELATIONSHIP delegation: matrix manager may delegate
      SELECT delegate_id INTO v_delegate
      FROM   workflow_delegations
      WHERE  delegator_id  = v_approver
        AND  is_active     = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_step.template_id)
      LIMIT  1;
    ELSE
      SELECT delegate_id INTO v_delegate
      FROM   workflow_delegations
      WHERE  delegator_id  = v_approver
        AND  is_active     = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_step.template_id)
      LIMIT  1;
    END IF;

    IF FOUND AND v_delegate IS NOT NULL THEN
      v_approver := v_delegate;
    END IF;
  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver IS
  'Resolves the single profile_id responsible for a given workflow step. '
  'Types: MANAGER, ROLE, DEPT_HEAD, SPECIFIC_USER, SELF, RULE_BASED, '
  'JOB_RELATIONSHIP, SUBJECT_EMPLOYEE. '
  'SUBJECT_EMPLOYEE (mig 528): resolves to subject_profile_id on the instance '
  '(the employee the workflow is about). For self-service = same as SELF. '
  'No delegation applied to SELF or SUBJECT_EMPLOYEE steps. '
  'Returns NULL for auto-skipped steps (JOB_RELATIONSHIP with missing manager).';


-- =============================================================================
-- 5. Sanity checks
-- =============================================================================

DO $$
BEGIN
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_name  = 'workflow_instances'
      AND  column_name = 'subject_profile_id'
  ), 'workflow_instances.subject_profile_id column missing';

  ASSERT (
    SELECT pg_get_constraintdef(oid)
    FROM   pg_constraint
    WHERE  conname = 'workflow_steps_approver_type_check'
  ) LIKE '%SUBJECT_EMPLOYEE%',
  'workflow_steps_approver_type_check does not include SUBJECT_EMPLOYEE';

  ASSERT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE  proname = 'wf_resolve_approver'
      AND  prosrc  LIKE '%SUBJECT_EMPLOYEE%'
  ), 'wf_resolve_approver missing SUBJECT_EMPLOYEE branch';

  ASSERT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE  proname = 'wf_submit'
      AND  prosrc  LIKE '%subject_profile_id%'
  ), 'wf_submit not populating subject_profile_id';
END $$;


-- =============================================================================
-- 6. Extend get_workflow_instance_routing with SUBJECT_EMPLOYEE display
--    Based on mig 339 body — adds SUBJECT_EMPLOYEE to resolvedName /
--    resolvedDesignation CASE blocks and adds subject_emp lateral join.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_workflow_instance_routing(p_instance_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance  RECORD;
  v_result    jsonb;
BEGIN
  SELECT submitted_by, template_id, subject_profile_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',    ws.step_order,
      'name',         ws.name,
      'approverType', ws.approver_type,
      'approverRole', ws.approver_role,
      'slaHours',     ws.sla_hours,
      'isCc',         ws.is_cc,
      'approvalMode', ws.approval_mode,
      'status', (
        SELECT CASE
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = p_instance_id
              AND wt.step_order  = ws.step_order
              AND wt.status = 'approved'
          ) THEN 'approved'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = p_instance_id
              AND wt.step_order  = ws.step_order
              AND wt.status = 'pending'
          ) THEN 'pending'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = p_instance_id
              AND wt.step_order  = ws.step_order
              AND wt.status = 'rejected'
          ) THEN 'rejected'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = p_instance_id
              AND wt.step_order  = ws.step_order
              AND wt.status = 'skipped'
          ) THEN 'skipped'
          ELSE 'upcoming'
        END
      ),
      'approvedAt', (
        SELECT wal.created_at
        FROM   workflow_action_log wal
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      -- ── resolvedName ──────────────────────────────────────────────────────
      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name, 'Dept. Head')
          WHEN 'ROLE' THEN
            CASE
              WHEN (SELECT COUNT(*) FROM workflow_tasks wt
                    WHERE wt.instance_id = p_instance_id
                      AND wt.step_order  = ws.step_order
                      AND wt.status NOT IN ('skipped')) = 1
              THEN (
                SELECT emp.name
                FROM   workflow_tasks wt
                JOIN   profiles  p   ON p.id  = wt.assigned_to
                JOIN   employees emp ON emp.id = p.employee_id
                WHERE  wt.instance_id = p_instance_id
                  AND  wt.step_order  = ws.step_order
                  AND  wt.status NOT IN ('skipped')
                LIMIT  1
              )
              ELSE COALESCE(role_row.name, ws.approver_role)
            END
          WHEN 'SELF'             THEN COALESCE(self_emp.name, 'You')
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.name, 'Employee')
          ELSE ws.name
        END,

      -- ── resolvedDesignation ───────────────────────────────────────────────
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE' THEN
            CASE
              WHEN (SELECT COUNT(*) FROM workflow_tasks wt
                    WHERE wt.instance_id = p_instance_id
                      AND wt.step_order  = ws.step_order
                      AND wt.status NOT IN ('skipped')) = 1
              THEN (
                SELECT emp.job_title
                FROM   workflow_tasks wt
                JOIN   profiles  p   ON p.id  = wt.assigned_to
                JOIN   employees emp ON emp.id = p.employee_id
                WHERE  wt.instance_id = p_instance_id
                  AND  wt.step_order  = ws.step_order
                  AND  wt.status NOT IN ('skipped')
                LIMIT  1
              )
              ELSE CASE WHEN ws.approval_mode = 'ALL_OF'
                        THEN 'All active members must approve'
                        ELSE 'All active members — first to approve wins'
                   END
            END
          WHEN 'SELF'             THEN NULL
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.job_title, 'Subject Employee')
          ELSE NULL
        END,

      -- ── roleMembers ───────────────────────────────────────────────────────
      'roleMembers',
        CASE ws.approver_type
          WHEN 'ROLE' THEN (
            CASE WHEN EXISTS (
              SELECT 1 FROM workflow_tasks wt
              WHERE wt.instance_id = p_instance_id
                AND wt.step_order  = ws.step_order
                AND wt.status NOT IN ('skipped')
            )
            THEN (
              SELECT jsonb_agg(
                jsonb_build_object('name', emp.name, 'jobTitle', emp.job_title)
                ORDER BY emp.name
              )
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status NOT IN ('skipped')
            )
            ELSE (
              SELECT jsonb_agg(
                jsonb_build_object('name', emp.name, 'jobTitle', emp.job_title)
                ORDER BY emp.name
              )
              FROM   user_roles ur
              JOIN   roles      r   ON r.id  = ur.role_id
              JOIN   profiles   p   ON p.id  = ur.profile_id
              JOIN   employees  emp ON emp.id = p.employee_id
              WHERE  r.code       = ws.approver_role
                AND  r.active     = true
                AND  ur.is_active = true
                AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
            )
            END
          )
          ELSE NULL::jsonb
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles    pr
    JOIN   employees   emp ON emp.id = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  LEFT JOIN LATERAL (
    SELECT r.name
    FROM   roles r
    WHERE  r.code = ws.approver_role AND r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type = 'ROLE'

  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles  sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  sp.id = v_instance.submitted_by
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')

  LEFT JOIN LATERAL (
    SELECT emp.name
    FROM   profiles  sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = v_instance.submitted_by
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'

  -- mig 528: resolve subject employee name for SUBJECT_EMPLOYEE steps
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   profiles  sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by)
    LIMIT  1
  ) subject_emp ON ws.approver_type = 'SUBJECT_EMPLOYEE'

  WHERE ws.template_id = v_instance.template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_instance_routing(uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_instance_routing(uuid) IS
  'Returns live routing chain for a workflow instance. '
  'Mig 339: ROLE step roleMembers now shows actual workflow_tasks assignees when '
  'tasks exist. Falls back to role definition members for future steps. '
  'Mig 528: SUBJECT_EMPLOYEE resolvedName/resolvedDesignation via subject_profile_id.';
