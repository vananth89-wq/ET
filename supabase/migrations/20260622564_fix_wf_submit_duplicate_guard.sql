-- Migration 564 — Fix wf_submit duplicate-instance guard
-- ────────────────────────────────────────────────────────
-- The partial unique index uq_workflow_instances_one_active_per_record (mig 247)
-- blocks on status IN ('in_progress', 'awaiting_clarification').
-- But wf_submit's pre-insert guard only checked status = 'in_progress'.
-- When an awaiting_clarification instance existed, the guard passed, the INSERT
-- hit the index, and Postgres returned a raw 23505 error to the UI.
-- Fix: broaden the guard to match the index — check both statuses and raise a
-- clean, user-readable EXCEPTION before the INSERT.
-- The frontend (AddEmployee.tsx mig 564) already surfaces this via modal popup.

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

  -- ── Duplicate-instance guard (mig 564: broadened to match unique index) ───
  -- uq_workflow_instances_one_active_per_record covers both 'in_progress' and
  -- 'awaiting_clarification'. Previously only 'in_progress' was checked, so an
  -- awaiting_clarification instance caused a raw 23505 DB error. Now both states
  -- are caught here with a clean user-readable message.
  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      IN ('in_progress', 'awaiting_clarification')
  ) THEN
    RAISE EXCEPTION
      'A workflow is already active for this record. '
      'Please complete or withdraw the existing workflow before submitting again.'
      USING ERRCODE = 'invalid_parameter_value';
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
      WHERE  delegator_id  = v_role_holder_id
        AND  is_active     = true
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

REVOKE ALL     ON FUNCTION wf_submit(text, text, uuid, jsonb, text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_submit(text, text, uuid, jsonb, text, uuid) TO authenticated;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb, text, uuid) IS
  'Mig 338: MANAGER/DEPT_HEAD auto-skip. '
  'Mig 480: ROLE step auto-skip when all role members are the submitter. '
  'Mig 493: concurrent termination guard. '
  'Mig 503: p_subject_employee_id stamps initiated_by_actor_id when subject != actor. '
  'Mig 528: subject_profile_id populated. '
  'Mig 564: duplicate guard broadened to IN (in_progress, awaiting_clarification) '
  'to match uq_workflow_instances_one_active_per_record index — prevents raw 23505.';
