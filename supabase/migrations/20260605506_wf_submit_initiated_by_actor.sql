-- =============================================================================
-- Migration 503: wf_submit + submit_change_request — on-behalf-of stamping
--
-- Decision #22: when HR (EMP_B) submits a workflow for EMP_A,
-- workflow_instances.initiated_by_actor_id = EMP_B's profile_id, so
-- ApproverInbox and EMP_A's own workflow view can show
-- "Submitted by EMP_B on behalf of EMP_A".
--
-- Changes:
-- 1. wf_submit — new optional param p_subject_employee_id uuid DEFAULT NULL.
--    If supplied and differs from auth.uid()'s employee, stamps initiated_by_actor_id.
-- 2. submit_change_request — threads p_record_id as p_subject_employee_id.
--    Also fixes data snapshot to use p_record_id (subject) not v_emp_id (actor)
--    when HR submits for another employee.
--
-- Backward-compatible: all existing callers without p_subject_employee_id unchanged.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. wf_submit — add p_subject_employee_id, stamp initiated_by_actor_id
-- ─────────────────────────────────────────────────────────────────────────────
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

  -- ── On-behalf-of stamp (mig 503) ─────────────────────────────────────────
  IF p_subject_employee_id IS NOT NULL THEN
    SELECT employee_id INTO v_submitter_emp_id FROM profiles WHERE id = auth.uid();
    IF v_submitter_emp_id IS DISTINCT FROM p_subject_employee_id THEN
      v_actor_id_to_stamp := auth.uid();
    END IF;
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
     submitted_by, current_step, status, metadata, initiated_by_actor_id)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata,
     v_actor_id_to_stamp)
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
  'Backward-compatible: p_subject_employee_id defaults to NULL.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. submit_change_request — thread p_record_id as p_subject_employee_id,
--    and use p_record_id for data snapshots when HR submits for another employee.
--
--    Two minimal diffs from mig 481:
--    a) Snapshot queries use COALESCE(p_record_id, v_emp_id) — so HR's snapshot
--       is the subject's current data, not HR's own data.
--    b) wf_submit call adds p_subject_employee_id => p_record_id.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code   text,
  p_record_id     uuid    DEFAULT NULL,
  p_proposed_data jsonb   DEFAULT '{}',
  p_action        text    DEFAULT 'update',
  p_comment       text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id          uuid;
  v_subject_emp_id  uuid;   -- mig 503: subject for snapshots (may differ from actor)
  v_template_id     uuid;
  v_template_code   text;
  v_pending_id      uuid;
  v_instance_id     uuid;
  v_current_row     jsonb   := NULL;
  v_current_data    jsonb   := NULL;
  v_key             text;
BEGIN
  IF p_module_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code is required.');
  END IF;

  IF p_module_code = 'expense_reports' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Use submit_expense() for expense_reports, not submit_change_request().'
    );
  END IF;

  SELECT p.employee_id INTO v_emp_id FROM profiles p WHERE p.id = auth.uid();

  -- mig 503: use p_record_id as subject when provided (e.g. HR submitting for EMP_A)
  v_subject_emp_id := COALESCE(p_record_id, v_emp_id);

  v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid());

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', format(
        'No active workflow assignment found for module "%s". '
        'Ask your administrator to configure one in Workflow → Assignments.',
        p_module_code
      )
    );
  END IF;

  SELECT code INTO v_template_code FROM workflow_templates WHERE id = v_template_id;

  -- ── Snapshot current data for diff display (uses subject, not actor) ────────
  IF v_subject_emp_id IS NOT NULL AND p_action = 'update' THEN

    CASE p_module_code

      WHEN 'profile_personal' THEN
        SELECT to_jsonb(ep.*)
        INTO   v_current_row
        FROM   employee_personal ep
        WHERE  ep.employee_id  = v_subject_emp_id
          AND  ep.effective_to = '9999-12-31'::date
          AND  ep.is_active    = true;

      WHEN 'profile_employment' THEN
        SELECT to_jsonb(ee.*)
        INTO   v_current_row
        FROM   employee_employment ee
        WHERE  ee.employee_id  = v_subject_emp_id
          AND  ee.effective_to = '9999-12-31'::date
          AND  ee.is_active    = true;

      WHEN 'profile_job_relationships' THEN
        SELECT jsonb_build_object(
          'set_id',         s.id,
          'effective_from', s.effective_from,
          'items',          COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'relationship_code',    i.relationship_code,
              'manager_employee_id',  i.manager_employee_id
            ))
            FROM employee_job_relationship_item i
            WHERE i.set_id = s.id
          ), '[]'::jsonb)
        )
        INTO v_current_row
        FROM employee_job_relationship_set s
        WHERE s.employee_id  = v_subject_emp_id
          AND s.is_active    = true
          AND s.effective_to = '9999-12-31'::date;

      WHEN 'profile_education' THEN
        IF p_record_id IS NOT NULL THEN
          SELECT to_jsonb(ee.*)
          INTO   v_current_row
          FROM   employee_education ee
          WHERE  ee.id        = p_record_id
            AND  ee.is_active = true;
        END IF;

      WHEN 'profile_contact' THEN
        SELECT to_jsonb(ec.*)
        INTO   v_current_row
        FROM   employee_contact ec
        WHERE  ec.employee_id = v_subject_emp_id;

      WHEN 'profile_address' THEN
        SELECT to_jsonb(ea.*)
        INTO   v_current_row
        FROM   employee_addresses ea
        WHERE  ea.employee_id = v_subject_emp_id;

      WHEN 'profile_passport' THEN
        SELECT to_jsonb(pp.*)
        INTO   v_current_row
        FROM   passports pp
        WHERE  pp.employee_id = v_subject_emp_id;

      WHEN 'profile_identification' THEN
        SELECT to_jsonb(ir.*)
        INTO   v_current_row
        FROM   identity_records ir
        WHERE  ir.employee_id = v_subject_emp_id;

      WHEN 'profile_emergency_contact' THEN
        SELECT to_jsonb(emg.*)
        INTO   v_current_row
        FROM   emergency_contacts emg
        WHERE  emg.employee_id = v_subject_emp_id
        ORDER  BY emg.created_at
        LIMIT  1;

      ELSE
        NULL;

    END CASE;

    IF v_current_row IS NOT NULL THEN
      v_current_data := '{}'::jsonb;
      FOR v_key IN SELECT jsonb_object_keys(p_proposed_data) LOOP
        IF v_current_row ? v_key THEN
          v_current_data := v_current_data || jsonb_build_object(v_key, v_current_row->v_key);
        END IF;
      END LOOP;
    END IF;

  END IF;

  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, current_data, submitted_by
  ) VALUES (
    p_module_code,
    p_record_id,
    p_action,
    COALESCE(p_proposed_data, '{}'),
    v_current_data,
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  -- mig 503: pass p_record_id as subject so wf_submit can stamp initiated_by_actor_id
  v_instance_id := wf_submit(
    p_template_code       => v_template_code,
    p_module_code         => p_module_code,
    p_record_id           => v_pending_id,
    p_metadata            => COALESCE(p_proposed_data, '{}'),
    p_comment             => NULLIF(trim(COALESCE(p_comment, '')), ''),
    p_subject_employee_id => p_record_id
  );

  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'pending_id',  v_pending_id,
    'instance_id', v_instance_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text, text) IS
  'Mig 481: workflow resolution fix — uses resolve_workflow_for_submission(). '
  'Mig 503: data snapshot uses subject employee (p_record_id), not actor; '
  'threads p_subject_employee_id to wf_submit for initiated_by_actor_id stamping.';

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- wf_submit now has 6 parameters
  ASSERT (
    SELECT MAX(pronargs) FROM pg_proc WHERE proname = 'wf_submit'
  ) = 6, 'wf_submit should have 6 parameters after mig 503';

  -- submit_change_request still has 5 parameters (unchanged signature)
  ASSERT (
    SELECT COUNT(*) FROM pg_proc WHERE proname = 'submit_change_request' AND pronargs = 5
  ) = 1, 'submit_change_request should have 5 parameters';

  RAISE NOTICE 'Mig 503 verification passed.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 503
-- =============================================================================
