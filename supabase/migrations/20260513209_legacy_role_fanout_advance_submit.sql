-- =============================================================================
-- Migration 209: Legacy ROLE fan-out in wf_advance_instance + wf_submit
--
-- PROBLEM
-- ───────
-- wf_advance_instance and wf_submit have a legacy path for steps where
-- approval_mode IS NULL (pre-mig-200 schema). That path calls
-- wf_resolve_approver() which uses LIMIT 1 — so ROLE-type legacy steps
-- only ever assign to one role holder, even when the role has many members.
--
-- Mig 208 fixed wf_force_advance. This migration fixes the normal flow.
--
-- ROOT CAUSE
-- ──────────
-- Both functions were written before multi-approver support. Mig 203 added
-- ROLE fan-out to the NEW multi-approver path (approval_mode IS NOT NULL) but
-- deliberately left the legacy path (approval_mode IS NULL) unchanged. The
-- Finance template uses the legacy schema (approver_type=ROLE on workflow_steps,
-- no rows in workflow_step_approvers), so it falls through to the legacy path.
--
-- FIX
-- ───
-- Add a third branch between the existing two:
--
--   approval_mode IS NOT NULL         → existing multi-approver path (unchanged)
--   approval_mode IS NULL, type=ROLE  → NEW: fan out to all active role holders
--   approval_mode IS NULL, other type → existing single-approver path (unchanged)
--
-- The fan-out loop is identical to the one in mig 203 / mig 208:
--   • delegation applied per-holder
--   • submitter skipped per-holder
--   • if v_tasks_created = 0 after the loop → step silently skipped (same as
--     multi-approver zero-task behaviour in wf_advance_instance)
--
-- SAFETY ANALYSIS
-- ───────────────
-- wf_approve (mig 204) already handles approval_mode IS NULL with multiple
-- sibling tasks. Its comment reads:
--   "Default (NULL): cancel any sibling tasks (ROLE fan-out), then advance.
--    For single-person steps there are no siblings — UPDATE affects 0 rows."
-- The engine was already designed for this — first to approve wins, others
-- cancelled. Our "Already Approved" modal (mig 208 frontend fix) handles the
-- race condition gracefully.
--
-- Functions NOT changed (verified safe):
--   wf_approve          — handles multi-task NULL mode already ✓
--   wf_reject           — rejects whole instance, unaffected ✓
--   wf_return_to_initiator — cancels all pending, unaffected ✓
--   wf_admin_decline    — cancels all pending, unaffected ✓
--   wf_reassign         — acts on a specific task, unaffected ✓
--   wf_resubmit         — calls wf_advance_instance, inherits fix ✓
--   wf_force_advance    — already fixed in mig 208 ✓
--
-- REMAINING GAP (out of scope for this migration)
-- ────────────────────────────────────────────────
-- wf_return_to_previous_step also calls wf_resolve_approver() for the step
-- it returns to. If that step is a legacy ROLE step, only one holder gets the
-- task back. This is a separate, lower-priority fix.
--
-- NO SCHEMA CHANGES — pure function replacements.
-- =============================================================================


-- =============================================================================
-- 1. wf_advance_instance
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
  -- Multi-approver + legacy ROLE fan-out variables
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
  -- Unchanged from mig 203.
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
  -- NEW in mig 209.
  -- Same fan-out loop as Path A / mig 208. Zero-task → silent skip + recurse,
  -- consistent with the multi-approver path. No removal/skip duplicate rules
  -- applied (per-holder submitter filtering is the only guard needed).
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
      -- All role holders were the submitter or had no active assignment.
      -- Silent skip: consistent with multi-approver zero-task behaviour.
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
  -- Unchanged from mig 203 — all removal rules, CC handling, skip rules intact.
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
  'Advances a workflow instance to the next active, non-condition-skipped step. '
  'Path A — Multi-approver (mig 201/203): approval_mode IS NOT NULL → fan out via workflow_step_approvers. '
  'Path B — Legacy ROLE (mig 209): approval_mode IS NULL AND approver_type=ROLE → fan out to all active role holders. '
  'Path C — Legacy single (unchanged): approval_mode IS NULL, non-ROLE → wf_resolve_approver, removal rules, CC. '
  'wf_approve NULL mode: first to approve wins, siblings cancelled (already supported). '
  'Removal Rule 1 (mig 163): approver = submitter → step silently removed (Path C only). '
  'Removal Rule 2 (mig 163): remove_duplicate_approver AND same approver next step (Path C only). '
  'CC steps auto-completed (mig 122, Path C only).';


-- =============================================================================
-- 2. wf_submit
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
  -- Removal (mig 163)
  v_remove_reason       text;
  -- Skip (mig 164)
  v_skip_reason         text;
  -- Shared lookahead
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
  -- Legacy ROLE fan-out (mig 209)
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

  -- ════════════════════════════════════════════════════════════════════════════
  -- Legacy ROLE fan-out for step 1 (mig 209)
  -- If first step is a legacy ROLE step, fan out to all active role holders.
  -- The existing removal/skip checks (mig 163/164) are designed for a single
  -- resolved approver and don't apply cleanly to a role group — per-holder
  -- submitter filtering is sufficient.
  -- If zero tasks created → exception (rolls back the whole INSERT above too).
  -- ════════════════════════════════════════════════════════════════════════════

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
      CONTINUE WHEN v_role_holder_id = auth.uid();  -- skip submitter

      SELECT delegate_id
      INTO   v_delegate_id
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
      RAISE EXCEPTION
        'wf_submit: no valid approvers for ROLE step 1 of template % '
        '(role ''%'' has no active members, or all members are the submitter)',
        p_template_code, v_first_step.approver_role;
    END IF;

    -- Audit log — use last v_task_id (one log row covers the submission)
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes, metadata)
    VALUES
      (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
       NULLIF(trim(p_comment), ''),
       jsonb_build_object('template_code', p_template_code));

    PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');
    RETURN v_instance_id;

  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- Existing flow — non-ROLE legacy step 1 (completely unchanged from mig 177)
  -- ════════════════════════════════════════════════════════════════════════════

  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_submit: cannot resolve approver for step 1 of template %',
                    p_template_code;
  END IF;

  -- ── Removal checks (mig 163) ──────────────────────────────────────────────
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

  -- ── Skip checks (mig 164) ─────────────────────────────────────────────────
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

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb, text) IS
  'Starts a new workflow instance. '
  'Legacy ROLE step 1 (mig 209): fans out to all active role holders — same as wf_advance_instance Path B. '
  'Non-ROLE step 1 (unchanged): removal checks (mig 163), skip checks (mig 164), CC auto-complete (mig 122). '
  'p_comment (mig 177) stored in action_log notes for the submitted row.';

-- =============================================================================
-- END OF MIGRATION 209
--
-- APPLY: paste this file into the Supabase SQL Editor and run.
--
-- VERIFY:
--   1. Submit to a template whose first step is legacy ROLE → all role members
--      get a pending task
--   2. Submit to a template whose ROLE step is not step 1 → when advance reaches
--      it, all role members get a pending task
--   3. First approval advances the instance; other tasks become 'cancelled'
--   4. The "Already Approved" modal appears for the second approver
--   5. Non-ROLE templates behave identically to before
-- =============================================================================
