-- =============================================================================
-- Migration 480 — wf_submit: auto-skip ROLE step when all members are submitter
-- =============================================================================
--
-- PROBLEM
-- ───────
-- wf_submit (mig 338) has three execution paths for step 1:
--
--   PATH A: ROLE fan-out (approver_type = 'ROLE', approval_mode IS NULL)
--     → loops all active role holders, skips the submitter
--     → IF v_tasks_created = 0 → RAISE EXCEPTION  ← BUG
--
--   PATH B: NULL approver (MANAGER / DEPT_HEAD)
--     → IF v_approver_id IS NULL → auto-skip + wf_advance_instance ✓
--
--   PATH C: normal / removal / skip-duplicate
--     → standard task creation or skip logic ✓
--
-- wf_advance_instance PATH B (mig 209) already handles subsequent ROLE steps
-- correctly: "Zero-task → silent skip + recurse, consistent with multi-approver."
-- wf_submit PATH A was never updated to match.
--
-- DESIRED BEHAVIOUR (confirmed by product owner)
-- ───────────────────────────────────────────────
-- Case 1: Role has N members, submitter is one of them.
--   → Create tasks for the remaining N-1 members. (Already works — no change.)
--
-- Case 2: Role has 1 member who IS the submitter, OR role has no active members.
--   → Auto-skip the step. Log 'auto_skipped'. Call wf_sync_module_status('submitted')
--     then wf_advance_instance. If no further steps, the workflow completes and the
--     hire is auto-approved/activated. This matches the MANAGER/DEPT_HEAD pattern.
--
-- THE CHANGE
-- ──────────
-- One block replaced, everything else byte-for-byte identical to mig 338:
--
--   BEFORE:
--     IF v_tasks_created = 0 THEN
--       RAISE EXCEPTION 'wf_submit: no valid approvers …';
--     END IF;
--
--   AFTER:
--     IF v_tasks_created = 0 THEN
--       INSERT INTO workflow_action_log … 'auto_skipped' …
--       PERFORM wf_sync_module_status(…, 'submitted');
--       PERFORM wf_advance_instance(v_instance_id);
--       RETURN v_instance_id;
--     END IF;
--
-- ORDERING PRESERVED
-- ──────────────────
-- wf_sync_module_status('submitted') is called BEFORE wf_advance_instance,
-- matching every other skip/advance path in wf_submit. This ensures:
--   - employee.status = 'Pending', locked = true is set before advancing
--   - If wf_advance_instance completes the workflow (no more steps),
--     wf_sync_module_status('approved') → wf_activate_employee fires correctly
--     from a Pending state (not Draft)
--
-- NO OTHER CHANGES
-- ────────────────
-- wf_advance_instance is untouched — PATH B already handles subsequent ROLE
-- steps with the same auto-skip + recurse pattern.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb DEFAULT '{}',
  p_comment       text DEFAULT NULL
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
     submitted_by, current_step, status, metadata)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata)
  RETURNING id INTO v_instance_id;

  -- ── Legacy ROLE fan-out for step 1 ────────────────────────────────────────
  -- Unchanged from mig 209 except the zero-task block (mig 480).
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

    -- ── mig 480: auto-skip when submitter is the only role member ─────────
    -- BEFORE (mig 338): RAISE EXCEPTION — blocked submission entirely.
    -- AFTER  (mig 480): auto-skip, matching wf_advance_instance PATH B and
    --                   the MANAGER/DEPT_HEAD pattern in wf_submit (mig 338).
    -- Execution order preserved: sync_module_status → advance_instance,
    -- same as every other skip/advance path in this function.
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
    -- ── end mig 480 change ────────────────────────────────────────────────

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

  -- ── NULL approver handling (mig 338 — unchanged) ─────────────────────────
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

  -- ── Removal checks (mig 163 — unchanged) ─────────────────────────────────
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

  -- ── Skip checks (mig 164 — unchanged) ────────────────────────────────────
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

  -- ── Normal first step (mig 209 — unchanged) ───────────────────────────────
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

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb, text) IS
  'Starts a new workflow instance. '
  'Mig 338: MANAGER/DEPT_HEAD steps with no resolvable approver are auto-skipped '
  '(logged as auto_skipped) and wf_advance_instance is called to route to the next step. '
  'Mig 480: Legacy ROLE step 1 with no valid approvers (all members are the submitter, '
  'or role is empty) now also auto-skips instead of raising an exception. '
  'Consistent with wf_advance_instance PATH B (mig 209) which already handled this '
  'for subsequent ROLE steps. '
  'All other step types with NULL approvers still raise an exception (config error). '
  'Removal checks (mig 163), skip checks (mig 164), CC auto-complete (mig 122) unchanged.';
