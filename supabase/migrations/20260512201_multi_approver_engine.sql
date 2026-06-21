-- =============================================================================
-- Migration 201: Multi-approver engine changes
--
-- CHANGES
-- ───────
-- 1. wf_resolve_approver_ex — new internal helper
--    Resolves an approver from explicit type/role/profile params rather than
--    a step row. Used by the multi-approver loop in wf_advance_instance.
--    Applies delegation chains identically to wf_resolve_approver.
--
-- 2. wf_advance_instance — multi-approver fan-out
--    When v_next_step.approval_mode IS NOT NULL:
--      • Loops over workflow_step_approvers for the step.
--      • Calls wf_resolve_approver_ex per co-approver.
--      • Creates one pending workflow_task per resolved (non-null, non-self)
--        approver.
--      • If zero tasks were created (all approvers resolved to submitter or
--        null), the step is silently skipped.
--    Single-approver steps (approval_mode IS NULL): existing path unchanged.
--
-- 3. wf_approve — ANY_OF / ALL_OF completion
--    ANY_OF: first approver to approve cancels all sibling pending tasks,
--            then advances the instance.
--    ALL_OF: approval is noted; instance advances only when the last pending
--            sibling task is also approved.
--    NULL (single): existing behaviour — advance immediately.
--
-- 4. wf_return_to_initiator — cancel sibling tasks
--    When an approver sends back a multi-approver step, all other pending
--    tasks for the same step are cancelled so the instance cleanly pauses.
--
-- 5. wf_resubmit — delegate step-1 creation to wf_advance_instance
--    Previously created the step-1 task inline (single-approver only).
--    Now sets current_step = 0 and calls wf_advance_instance, which handles
--    both single and multi-approver step-1 creation correctly.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. wf_resolve_approver_ex — resolve an approver from explicit params
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resolve_approver_ex(
  p_approver_type       text,
  p_approver_role       text,
  p_approver_profile_id uuid,
  p_template_id         uuid,
  p_instance_id         uuid
) RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance      RECORD;
  v_submitter_emp RECORD;
  v_approver      uuid;
  v_delegate      uuid;
BEGIN
  SELECT submitted_by, metadata, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver_ex: instance % not found', p_instance_id;
  END IF;

  -- Submitter's employee record (needed for MANAGER and DEPT_HEAD)
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_submitter_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_instance.submitted_by;

  -- ── Resolve by type ───────────────────────────────────────────────────────
  CASE p_approver_type

    WHEN 'MANAGER' THEN
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_submitter_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    WHEN 'ROLE' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id AND r.code = p_approver_role
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
      v_approver := p_approver_profile_id;

    WHEN 'RULE_BASED' THEN
      -- Not meaningful without a step_id for condition evaluation.
      -- Fall back to MANAGER for RULE_BASED co-approvers.
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_submitter_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation ──────────────────────────────────────────────────────
  IF v_approver IS NOT NULL THEN
    SELECT delegate_id INTO v_delegate
    FROM   workflow_delegations
    WHERE  delegator_id  = v_approver
      AND  is_active     = true
      AND  CURRENT_DATE BETWEEN from_date AND to_date
      AND  (template_id IS NULL OR template_id = p_template_id)
    LIMIT  1;

    IF v_delegate IS NOT NULL THEN
      v_approver := v_delegate;
    END IF;
  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver_ex(text, text, uuid, uuid, uuid) IS
  'Internal helper: resolves an approver from explicit type/role/profile params '
  'with delegation applied. Used by the multi-approver loop in wf_advance_instance.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. wf_advance_instance — multi-approver fan-out
-- ═════════════════════════════════════════════════════════════════════════════

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

    -- Create one task per co-approver in workflow_step_approvers
    FOR v_co IN
      SELECT *
      FROM   workflow_step_approvers
      WHERE  step_id = v_next_step.id
      ORDER  BY sort_order
    LOOP
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

      -- Compute SLA deadline
      v_due_at := CASE
        WHEN v_next_step.sla_hours IS NOT NULL
        THEN now() + (v_next_step.sla_hours * interval '1 hour')
        ELSE NULL
      END;

      INSERT INTO workflow_tasks
        (instance_id, step_id, step_order, assigned_to, due_at)
      VALUES
        (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
      RETURNING id INTO v_new_task_id;

      v_tasks_created := v_tasks_created + 1;

      -- Notify each co-approver
      PERFORM wf_queue_notification(
        p_instance_id,
        'wf.task_assigned',
        v_approver_id,
        jsonb_build_object(
          'step_name',   v_next_step.name,
          'module_code', v_instance.module_code,
          'approval_mode', v_next_step.approval_mode
        )
      );
    END LOOP;

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
  'Removal Rule 1 (mig 163): approver = submitter → step silently removed. '
  'Removal Rule 2 (mig 163): remove_duplicate_approver=true AND next step same approver. '
  'CC steps auto-completed (mig 122).';


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. wf_approve — ANY_OF / ALL_OF completion logic
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_approve(
  p_task_id uuid,
  p_notes   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task          RECORD;
  v_instance      RECORD;
  v_approval_mode text;
  v_pending_count integer;
BEGIN
  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_approve: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_approve: task is not pending (current status: %)', v_task.status;
  END IF;

  -- Allow assigned approver OR admin / workflow.admin
  IF v_task.assigned_to != auth.uid()
     AND NOT has_role('admin')
     AND NOT has_permission('workflow.admin')
  THEN
    RAISE EXCEPTION 'wf_approve: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_approve: workflow instance is not active (status: %)', v_instance.status;
  END IF;

  -- ── Mark this task approved ───────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'approved',
         notes    = p_notes,
         acted_at = now()
  WHERE  id = p_task_id;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'approved', v_task.step_order, p_notes);

  -- ── Check approval_mode for multi-approver handling ───────────────────────
  SELECT ws.approval_mode INTO v_approval_mode
  FROM   workflow_steps ws
  WHERE  ws.id = v_task.step_id;

  IF v_approval_mode = 'ANY_OF' THEN
    -- First approver wins — cancel all other pending sibling tasks
    UPDATE workflow_tasks
    SET    status   = 'cancelled',
           acted_at = now(),
           notes    = 'Cancelled: another approver approved first (ANY_OF)'
    WHERE  instance_id = v_task.instance_id
      AND  step_order  = v_task.step_order
      AND  status      = 'pending'
      AND  id          != p_task_id;

    -- Advance to next step
    PERFORM wf_advance_instance(v_task.instance_id);

  ELSIF v_approval_mode = 'ALL_OF' THEN
    -- Only advance when all sibling tasks are approved (none still pending)
    SELECT COUNT(*)
    INTO   v_pending_count
    FROM   workflow_tasks
    WHERE  instance_id = v_task.instance_id
      AND  step_order  = v_task.step_order
      AND  status      = 'pending'
      AND  id          != p_task_id;

    IF v_pending_count = 0 THEN
      -- Last required approval — advance
      PERFORM wf_advance_instance(v_task.instance_id);
    END IF;
    -- Otherwise wait — more co-approvers still need to act

  ELSE
    -- Single approver (NULL) — advance immediately (existing behaviour)
    PERFORM wf_advance_instance(v_task.instance_id);
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_approve(uuid, text) IS
  'Approves a pending workflow task. '
  'ANY_OF (mig 201): cancels sibling pending tasks, then advances. '
  'ALL_OF (mig 201): advances only when the last pending sibling also approved. '
  'NULL (single): advances immediately (original behaviour). '
  'Callable by assigned approver or admin / workflow.admin.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. wf_return_to_initiator — cancel sibling tasks for multi-approver steps
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_return_to_initiator(
  p_task_id uuid,
  p_message text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  IF p_message IS NULL OR trim(p_message) = '' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: a clarification message is required';
  END IF;

  IF char_length(p_message) > 1000 THEN
    RAISE EXCEPTION 'wf_return_to_initiator: message must be 1 000 characters or fewer (got %)', char_length(p_message);
  END IF;

  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_return_to_initiator: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: task is not pending (current: %)', v_task.status;
  END IF;

  IF v_task.assigned_to != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_return_to_initiator: you are not assigned to this task';
  END IF;

  SELECT id, submitted_by, status, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_return_to_initiator: instance is not in progress (status: %)',
                    v_instance.status;
  END IF;

  -- ── Mark this task returned ───────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'returned',
         notes    = p_message,
         acted_at = now()
  WHERE  id = p_task_id;

  -- ── Cancel any sibling pending tasks (multi-approver steps) ──────────────
  -- For ANY_OF / ALL_OF steps, other approvers' tasks should be cancelled
  -- so the instance cleanly pauses at awaiting_clarification.
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now(),
         notes    = 'Cancelled: request returned to initiator by co-approver'
  WHERE  instance_id = v_task.instance_id
    AND  step_order  = v_task.step_order
    AND  status      = 'pending'
    AND  id          != p_task_id;

  -- ── Pause the instance ────────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status     = 'awaiting_clarification',
         updated_at = now()
  WHERE  id = v_task.instance_id;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    v_task.instance_id, p_task_id, auth.uid(),
    'returned_to_initiator',
    v_task.step_order,
    p_message,
    jsonb_build_object('step_id', v_task.step_id)
  );

  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.clarification_requested',
    v_instance.submitted_by,
    jsonb_build_object('message', p_message)
  );
END;
$$;

COMMENT ON FUNCTION wf_return_to_initiator(uuid, text) IS
  'Approver returns request to submitter for clarification. '
  'Multi-approver (mig 201): cancels sibling pending tasks so the instance '
  'cleanly pauses at awaiting_clarification. '
  'Instance is paused; submitter calls wf_resubmit() to resume from Step 1. '
  'Message capped at 1 000 chars.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. wf_resubmit — delegate step-1 creation to wf_advance_instance
--    This ensures multi-approver step-1 fans out correctly.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resubmit(
  p_instance_id uuid,
  p_response    text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  SELECT id, submitted_by, status, current_step, template_id, module_code, metadata
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resubmit: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'awaiting_clarification' THEN
    RAISE EXCEPTION 'wf_resubmit: instance is not awaiting clarification (status: %)',
                    v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_resubmit: only the original submitter can resubmit';
  END IF;

  -- ── Cancel any stray pending tasks (defensive) ────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- ── Reset to step 0 and resume ────────────────────────────────────────────
  -- Setting current_step = 0 lets wf_advance_instance find step 1
  -- (step_order > 0) and create tasks correctly for both single and
  -- multi-approver step-1 configurations.
  UPDATE workflow_instances
  SET    status       = 'in_progress',
         current_step = 0,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES (
    p_instance_id, NULL, auth.uid(),
    'resubmitted',
    0,
    COALESCE(p_response, 'Submitter resubmitted after clarification.')
  );

  -- ── Create tasks for step 1 (handles multi-approver transparently) ────────
  PERFORM wf_advance_instance(p_instance_id);

END;
$$;

COMMENT ON FUNCTION wf_resubmit(uuid, text) IS
  'Submitter responds to clarification and resubmits from Step 1. '
  'Now delegates task creation to wf_advance_instance (mig 201) so '
  'multi-approver step-1 fans out correctly. '
  'Full approval chain runs again from the beginning.';


-- ── Permissions ───────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION wf_resolve_approver_ex(text, text, uuid, uuid, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'wf_resolve_approver_ex',
  'wf_advance_instance',
  'wf_approve',
  'wf_return_to_initiator',
  'wf_resubmit'
)
ORDER BY proname;

-- Expected: 5 rows

-- =============================================================================
-- END OF MIGRATION 201
-- =============================================================================
