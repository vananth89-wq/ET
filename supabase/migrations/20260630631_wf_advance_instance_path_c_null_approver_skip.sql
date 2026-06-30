-- =============================================================================
-- Migration 631: wf_advance_instance — fix Path C null-approver silent stall
--
-- BUG
-- ───
-- Path C (legacy single-approver, approval_mode IS NULL, non-ROLE type) stalls
-- permanently when wf_resolve_approver returns NULL:
--
--   IF v_approver_id IS NULL THEN
--     UPDATE workflow_instances SET current_step = v_next_step.step_order ...
--     RETURN;  ← no task created, no recursion, no completion
--   END IF;
--
-- Paths A and B already handle zero-task correctly — they log 'step_removed'
-- and call PERFORM wf_advance_instance(p_instance_id) to recurse. Path C must
-- do the same.
--
-- SYMPTOM
-- ───────
-- For termination_reversal workflows, after the final named approver (e.g.
-- Vijaya Bharathi) acts, wf_advance_instance runs and finds the next step.
-- If that step's approver_type resolves to NULL (SUBJECT_EMPLOYEE on a
-- terminated employee whose profile has is_active=false, or a MANAGER step
-- with no manager), the instance gets stuck in_progress forever — the Complete
-- bubble stays grey, wf_sync_module_status is never called, the reversal stays
-- PENDING.
--
-- FIX
-- ───
-- Replace the null-approver RETURN with the same pattern as Paths A/B:
--   1. Log 'step_removed' to workflow_action_log
--   2. PERFORM wf_advance_instance(p_instance_id) — recurse to next step
--   3. RETURN
--
-- This is safe: if there truly are no more steps, the recursive call hits the
-- NOT FOUND block and completes the instance normally.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_advance_instance(
  p_instance_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance            RECORD;
  v_next_step           RECORD;
  v_approver_id         uuid;
  v_due_at              timestamptz;
  v_new_task_id         uuid;
  v_remove_dup          boolean := false;
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
  v_remove_reason       text;
  v_co                  RECORD;
  v_tasks_created       integer := 0;
  v_role_holder_id      uuid;
  v_delegate_id         uuid;
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- ── Find next active, non-skipped step ────────────────────────────────────
  SELECT ws.*
  INTO   v_next_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  > v_instance.current_step
    AND  ws.is_active   = true
    AND  NOT wf_evaluate_skip_step(ws.id, v_instance.metadata)
  ORDER  BY ws.step_order
  LIMIT  1;

  IF NOT FOUND THEN
    -- ── All steps done — complete the instance ──────────────────────────────
    UPDATE workflow_instances
    SET    status       = 'approved',
           updated_at   = now(),
           completed_at = now()
    WHERE  id = p_instance_id;

    INSERT INTO workflow_action_log
      (instance_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
       'All approval steps completed');

    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.completed',
      v_instance.submitted_by,
      jsonb_build_object('module_code', v_instance.module_code)
    );

    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');
    RETURN;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH A: MULTI-APPROVER (approval_mode IS NOT NULL)
  -- ════════════════════════════════════════════════════════════════════════════

  IF v_next_step.approval_mode IS NOT NULL THEN

    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    v_due_at := CASE
      WHEN v_next_step.sla_hours IS NOT NULL
      THEN now() + (v_next_step.sla_hours * interval '1 hour')
      ELSE NULL
    END;

    FOR v_co IN
      SELECT *
      FROM   workflow_step_approvers
      WHERE  step_id = v_next_step.id
      ORDER  BY sort_order
    LOOP

      IF v_co.approver_type = 'ROLE' AND v_co.approver_role IS NOT NULL THEN

        FOR v_role_holder_id IN
          SELECT ur.profile_id
          FROM   user_roles ur
          JOIN   roles r ON r.id = ur.role_id
          WHERE  r.code       = v_co.approver_role
            AND  r.active     = true
            AND  ur.is_active = true
            AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
        LOOP
          CONTINUE WHEN v_role_holder_id = v_instance.submitted_by;

          SELECT delegate_id
          INTO   v_delegate_id
          FROM   workflow_delegations
          WHERE  delegator_id = v_role_holder_id
            AND  is_active    = true
            AND  CURRENT_DATE BETWEEN from_date AND to_date
            AND  (template_id IS NULL OR template_id = v_instance.template_id)
          LIMIT  1;

          v_approver_id := COALESCE(v_delegate_id, v_role_holder_id);
          CONTINUE WHEN v_approver_id = v_instance.submitted_by;

          INSERT INTO workflow_tasks
            (instance_id, step_id, step_order, assigned_to, due_at)
          VALUES
            (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
          RETURNING id INTO v_new_task_id;

          v_tasks_created := v_tasks_created + 1;

          PERFORM wf_queue_notification(
            p_instance_id, 'wf.task_assigned', v_approver_id,
            jsonb_build_object(
              'step_name',     v_next_step.name,
              'module_code',   v_instance.module_code,
              'approval_mode', v_next_step.approval_mode,
              'role_code',     v_co.approver_role
            )
          );
        END LOOP;

      ELSE

        v_approver_id := wf_resolve_approver_ex(
          v_co.approver_type,
          v_co.approver_role,
          v_co.approver_profile_id,
          v_instance.template_id,
          p_instance_id
        );

        CONTINUE WHEN v_approver_id IS NULL;
        CONTINUE WHEN v_approver_id = v_instance.submitted_by;

        INSERT INTO workflow_tasks
          (instance_id, step_id, step_order, assigned_to, due_at)
        VALUES
          (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
        RETURNING id INTO v_new_task_id;

        v_tasks_created := v_tasks_created + 1;

        PERFORM wf_queue_notification(
          p_instance_id, 'wf.task_assigned', v_approver_id,
          jsonb_build_object(
            'step_name',     v_next_step.name,
            'module_code',   v_instance.module_code,
            'approval_mode', v_next_step.approval_mode
          )
        );

      END IF;
    END LOOP;

    IF v_tasks_created = 0 THEN
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes)
      VALUES
        (p_instance_id, NULL, auth.uid(), 'step_removed',
         v_next_step.step_order,
         'Multi-approver step skipped: no valid co-approvers resolved');
      PERFORM wf_advance_instance(p_instance_id);
      RETURN;
    END IF;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, NULL, auth.uid(), 'step_advanced',
       v_next_step.step_order,
       format('Multi-approver step activated (%s tasks, mode=%s)',
              v_tasks_created, v_next_step.approval_mode));
    RETURN;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH B: LEGACY ROLE FAN-OUT (approval_mode IS NULL, approver_type = ROLE)
  -- ════════════════════════════════════════════════════════════════════════════

  ELSIF v_next_step.approver_type = 'ROLE'
    AND v_next_step.approver_role IS NOT NULL THEN

    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    v_due_at := CASE
      WHEN v_next_step.sla_hours IS NOT NULL
      THEN now() + (v_next_step.sla_hours * interval '1 hour')
      ELSE NULL
    END;

    FOR v_role_holder_id IN
      SELECT ur.profile_id
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      WHERE  r.code       = v_next_step.approver_role
        AND  r.active     = true
        AND  ur.is_active = true
        AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
    LOOP
      CONTINUE WHEN v_role_holder_id = v_instance.submitted_by;

      SELECT delegate_id
      INTO   v_delegate_id
      FROM   workflow_delegations
      WHERE  delegator_id = v_role_holder_id
        AND  is_active    = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_instance.template_id)
      LIMIT  1;

      v_approver_id := COALESCE(v_delegate_id, v_role_holder_id);
      CONTINUE WHEN v_approver_id = v_instance.submitted_by;

      INSERT INTO workflow_tasks
        (instance_id, step_id, step_order, assigned_to, due_at)
      VALUES
        (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
      RETURNING id INTO v_new_task_id;

      v_tasks_created := v_tasks_created + 1;

      PERFORM wf_queue_notification(
        p_instance_id, 'wf.task_assigned', v_approver_id,
        jsonb_build_object(
          'step_name',   v_next_step.name,
          'module_code', v_instance.module_code,
          'role_code',   v_next_step.approver_role
        )
      );
    END LOOP;

    IF v_tasks_created = 0 THEN
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes)
      VALUES
        (p_instance_id, NULL, auth.uid(), 'step_removed',
         v_next_step.step_order,
         'Legacy ROLE step skipped: no valid role holders resolved (all are submitter or role is empty)');
      PERFORM wf_advance_instance(p_instance_id);
      RETURN;
    END IF;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced',
       v_next_step.step_order,
       format('Legacy ROLE step activated (%s tasks)', v_tasks_created));
    RETURN;

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- PATH C: LEGACY SINGLE-APPROVER (approval_mode IS NULL, non-ROLE type)
  -- ════════════════════════════════════════════════════════════════════════════

  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    -- ── FIX (mig 631): skip step and recurse instead of silently stalling ───
    -- Previously this block just set current_step and returned, leaving the
    -- instance permanently in_progress with no pending task and no completion.
    -- Now we log step_removed and recurse — consistent with Paths A and B.
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance % — skipping',
                  v_next_step.step_order, p_instance_id;
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, NULL, auth.uid(), 'step_removed',
       v_next_step.step_order,
       format('Path C step skipped: wf_resolve_approver returned NULL for approver_type=%s',
              v_next_step.approver_type));
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;
    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ── Removal Rule 1: initiator-as-approver ────────────────────────────────
  -- (reached only when v_approver_id IS NOT NULL)
  IF v_approver_id = v_instance.submitted_by THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  -- ── Removal Rule 2: consecutive duplicate approver ────────────────────────
  IF v_remove_reason IS NULL THEN
    SELECT remove_duplicate_approver INTO v_remove_dup
    FROM   workflow_templates
    WHERE  id = v_instance.template_id;

    IF v_remove_dup THEN
      SELECT ws2.*
      INTO   v_lookahead_step
      FROM   workflow_steps ws2
      WHERE  ws2.template_id = v_instance.template_id
        AND  ws2.step_order  > v_next_step.step_order
        AND  ws2.is_active   = true
        AND  NOT wf_evaluate_skip_step(ws2.id, v_instance.metadata)
      ORDER  BY ws2.step_order
      LIMIT  1;

      IF FOUND THEN
        v_lookahead_approver := wf_resolve_approver(v_lookahead_step.id, p_instance_id);
        IF v_lookahead_approver IS NOT NULL AND v_lookahead_approver = v_approver_id THEN
          v_remove_reason :=
            'Step removed: same approver appears in next step (remove_duplicate_approver=true)';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_remove_reason IS NOT NULL THEN
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, NULL, auth.uid(), 'step_removed',
       v_next_step.step_order, v_remove_reason);

    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ── Compute SLA deadline ──────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_next_step.is_cc      THEN NULL
    WHEN v_next_step.sla_hours IS NOT NULL
    THEN now() + (v_next_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create task ───────────────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  UPDATE workflow_instances
  SET    current_step = v_next_step.step_order,
         updated_at   = now()
  WHERE  id = p_instance_id;

  PERFORM wf_queue_notification(
    p_instance_id,
    COALESCE(
      (SELECT wnt.code FROM workflow_notification_templates wnt
       WHERE wnt.id = v_next_step.notification_template_id),
      'wf.task_assigned'
    ),
    v_approver_id,
    jsonb_build_object(
      'step_name',   v_next_step.name,
      'module_code', v_instance.module_code
    )
  );

  -- ── CC step: auto-complete, then advance ──────────────────────────────────
  IF v_next_step.is_cc THEN
    UPDATE workflow_tasks
    SET    status   = 'approved',
           acted_at = now(),
           notes    = 'CC — auto-notified'
    WHERE  id = v_new_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, v_new_task_id, auth.uid(), 'cc_notified',
       v_next_step.step_order, 'CC step — notification sent, auto-completed');

    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES
    (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

END;
$$;

COMMENT ON FUNCTION wf_advance_instance(uuid) IS
  'Mig 209: Legacy ROLE fan-out (Path B). '
  'Mig 631: Path C null-approver now skips step + recurses instead of silently '
  'stalling (was: set current_step + RETURN with no task and no completion). '
  'Path A — Multi-approver: approval_mode IS NOT NULL. '
  'Path B — Legacy ROLE: approval_mode IS NULL AND approver_type=ROLE. '
  'Path C — Legacy single: approval_mode IS NULL, non-ROLE. '
  'All three paths now recurse on zero-task/null-approver to ensure completion.';
