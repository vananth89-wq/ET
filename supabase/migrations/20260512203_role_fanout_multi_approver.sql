-- =============================================================================
-- Migration 203: ROLE fan-out in multi-approver mode
--
-- PROBLEM
-- ───────
-- When a workflow_step_approvers row has approver_type = 'ROLE', the mig 201
-- engine calls wf_resolve_approver_ex(), which uses LIMIT 1 and returns only
-- ONE role holder. For a Finance role with 2 members, only one gets a task.
-- This defeats the purpose of multi-approver mode when using role-based steps.
--
-- FIX
-- ───
-- In wf_advance_instance, for the multi-approver fan-out loop, detect when
-- v_co.approver_type = 'ROLE' and iterate over ALL active role holders instead
-- of calling wf_resolve_approver_ex (LIMIT 1). Each holder gets their own task,
-- with delegation applied per-holder.
--
-- Non-ROLE co-approver entries (SPECIFIC_USER, MANAGER, DEPT_HEAD, SELF) are
-- unchanged — they still call wf_resolve_approver_ex.
--
-- SCOPE
-- ─────
-- Only wf_advance_instance is changed (multi-approver branch only).
-- wf_approve, wf_return_to_initiator, wf_resubmit are unchanged.
-- Single-approver path (approval_mode IS NULL) is unchanged.
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
  -- Single-approver removal logic (existing)
  v_remove_dup          boolean := false;
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
  v_remove_reason       text;
  -- Multi-approver loop variables
  v_co                  RECORD;
  v_tasks_created       integer := 0;
  -- ROLE fan-out (mig 203)
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
  -- MULTI-APPROVER PATH (approval_mode IS NOT NULL)
  -- ════════════════════════════════════════════════════════════════════════════

  IF v_next_step.approval_mode IS NOT NULL THEN

    -- Advance current_step first so the view shows the right step
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    -- Compute SLA deadline once (same for all tasks in this step)
    v_due_at := CASE
      WHEN v_next_step.sla_hours IS NOT NULL
      THEN now() + (v_next_step.sla_hours * interval '1 hour')
      ELSE NULL
    END;

    -- Iterate over every co-approver entry for this step
    FOR v_co IN
      SELECT *
      FROM   workflow_step_approvers
      WHERE  step_id = v_next_step.id
      ORDER  BY sort_order
    LOOP

      -- ── ROLE type: fan out to ALL active holders (mig 203) ────────────────
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
          -- Skip if this holder is the submitter
          CONTINUE WHEN v_role_holder_id = v_instance.submitted_by;

          -- Apply delegation for this specific holder
          SELECT delegate_id
          INTO   v_delegate_id
          FROM   workflow_delegations
          WHERE  delegator_id = v_role_holder_id
            AND  is_active    = true
            AND  CURRENT_DATE BETWEEN from_date AND to_date
            AND  (template_id IS NULL OR template_id = v_instance.template_id)
          LIMIT  1;

          v_approver_id := COALESCE(v_delegate_id, v_role_holder_id);

          -- Skip if delegation resolved back to submitter
          CONTINUE WHEN v_approver_id = v_instance.submitted_by;

          INSERT INTO workflow_tasks
            (instance_id, step_id, step_order, assigned_to, due_at)
          VALUES
            (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
          RETURNING id INTO v_new_task_id;

          v_tasks_created := v_tasks_created + 1;

          PERFORM wf_queue_notification(
            p_instance_id,
            'wf.task_assigned',
            v_approver_id,
            jsonb_build_object(
              'step_name',     v_next_step.name,
              'module_code',   v_instance.module_code,
              'approval_mode', v_next_step.approval_mode,
              'role_code',     v_co.approver_role
            )
          );
        END LOOP;

      -- ── All other types: use wf_resolve_approver_ex (unchanged) ──────────
      ELSE

        v_approver_id := wf_resolve_approver_ex(
          v_co.approver_type,
          v_co.approver_role,
          v_co.approver_profile_id,
          v_instance.template_id,
          p_instance_id
        );

        -- Skip if unresolved or if approver is the submitter
        CONTINUE WHEN v_approver_id IS NULL;
        CONTINUE WHEN v_approver_id = v_instance.submitted_by;

        INSERT INTO workflow_tasks
          (instance_id, step_id, step_order, assigned_to, due_at)
        VALUES
          (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
        RETURNING id INTO v_new_task_id;

        v_tasks_created := v_tasks_created + 1;

        PERFORM wf_queue_notification(
          p_instance_id,
          'wf.task_assigned',
          v_approver_id,
          jsonb_build_object(
            'step_name',     v_next_step.name,
            'module_code',   v_instance.module_code,
            'approval_mode', v_next_step.approval_mode
          )
        );

      END IF; -- ROLE vs other types

    END LOOP; -- co-approvers loop

    IF v_tasks_created = 0 THEN
      -- No valid co-approvers resolved (all null or all = submitter).
      -- Log and skip the step silently, then recurse.
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes)
      VALUES
        (p_instance_id, NULL, auth.uid(), 'step_removed',
         v_next_step.step_order,
         'Multi-approver step skipped: no valid co-approvers resolved');

      PERFORM wf_advance_instance(p_instance_id);
      RETURN;
    END IF;

    -- Log the step activation
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, NULL, auth.uid(), 'step_advanced',
       v_next_step.step_order,
       format('Multi-approver step activated (%s tasks, mode=%s)',
              v_tasks_created, v_next_step.approval_mode));

    RETURN;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- SINGLE-APPROVER PATH (approval_mode IS NULL) — existing logic unchanged
  -- ════════════════════════════════════════════════════════════════════════════

  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance %',
                  v_next_step.step_order, p_instance_id;
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;
    RETURN;
  END IF;

  -- ── Removal Rule 1: initiator-as-approver ────────────────────────────────
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

  -- ── Execute removal ───────────────────────────────────────────────────────
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

  -- ── Create task for next step ─────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  UPDATE workflow_instances
  SET    current_step = v_next_step.step_order,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Notify assignee ───────────────────────────────────────────────────────
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

  -- ── Regular step: log and stop ────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES
    (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

END;
$$;

COMMENT ON FUNCTION wf_advance_instance(uuid) IS
  'Advances a workflow instance to the next active, non-condition-skipped step. '
  'Multi-approver (mig 201): when approval_mode IS NOT NULL, fans out tasks to '
  'all co-approvers in workflow_step_approvers. '
  'ROLE fan-out (mig 203): ROLE co-approvers create one task per active role holder. '
  'Removal Rule 1 (mig 163): approver = submitter → step silently removed. '
  'Removal Rule 2 (mig 163): remove_duplicate_approver=true AND next step same approver. '
  'CC steps auto-completed (mig 122).';


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT proname, prosrc LIKE '%v_role_holder_id%' AS has_role_fanout
FROM   pg_proc
WHERE  proname = 'wf_advance_instance';

-- Expected: 1 row with has_role_fanout = true

-- =============================================================================
-- END OF MIGRATION 203
-- =============================================================================
