-- =============================================================================
-- Migration 204: Simplify approval_mode — Option A
--
-- BACKGROUND
-- ──────────
-- Migrations 200-203 introduced three modes: null (single), ANY_OF, ALL_OF,
-- with an explicit co-approver list in workflow_step_approvers.
--
-- After UX review the model is simplified to two states:
--
--   approval_mode IS NULL  (default)
--     • ROLE type: fan out to ALL active role holders; first to approve wins.
--       Engine behaviour is the same as the old ANY_OF but automatic — no
--       explicit co-approver list required. Adding/removing role members is
--       picked up at runtime with no template change.
--     • All other types (MANAGER, DEPT_HEAD, SPECIFIC_USER, SELF, RULE_BASED):
--       single task, advances immediately on approval. Unchanged.
--
--   approval_mode = 'ALL_OF'
--     • ROLE type: every active role holder must approve before advancing.
--     • Single-person types: behaves identically to default (only 1 person).
--
-- WHAT CHANGES
-- ────────────
-- 1. workflow_steps.approval_mode:
--      • Existing 'ANY_OF' rows → NULL (same runtime behaviour).
--      • CHECK constraint tightened: only 'ALL_OF' or NULL allowed.
-- 2. workflow_step_approvers:
--      • All rows deleted (table kept for backward-compat / rollback).
--      • No longer written to by the engine.
-- 3. wf_advance_instance — rewritten (simpler):
--      • ROLE type always fans out (was in multi-approver branch only).
--      • workflow_step_approvers loop removed.
-- 4. wf_approve — rewritten (simpler):
--      • NULL mode: cancel siblings if any, then advance.
--      • ALL_OF: advance only when last sibling approved.
--      • ANY_OF branch removed.
-- 5. get_workflow_participants — updated:
--      • coApprovers subquery removed (always returns null).
--      • approvalMode now only 'ALL_OF' | null.
-- =============================================================================


-- ── 1. Convert ANY_OF → NULL ──────────────────────────────────────────────────

UPDATE workflow_steps
SET    approval_mode = NULL
WHERE  approval_mode = 'ANY_OF';


-- ── 2. Tighten CHECK constraint ───────────────────────────────────────────────

ALTER TABLE workflow_steps
  DROP CONSTRAINT IF EXISTS workflow_steps_approval_mode_check;

ALTER TABLE workflow_steps
  ADD CONSTRAINT workflow_steps_approval_mode_check
  CHECK (approval_mode IN ('ALL_OF') OR approval_mode IS NULL);


-- ── 3. Clear workflow_step_approvers (no longer used) ────────────────────────

DELETE FROM workflow_step_approvers;

COMMENT ON TABLE workflow_step_approvers IS
  'Deprecated by mig 204 (Option A simplification). '
  'Rows cleared; table retained for rollback safety only.';


-- ── 4. wf_advance_instance ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION wf_advance_instance(
  p_instance_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance           RECORD;
  v_next_step          RECORD;
  v_approver_id        uuid;
  v_due_at             timestamptz;
  v_new_task_id        uuid;
  -- Single-approver removal logic
  v_remove_dup         boolean := false;
  v_lookahead_step     RECORD;
  v_lookahead_approver uuid;
  v_remove_reason      text;
  -- ROLE fan-out
  v_role_holder_id     uuid;
  v_delegate_id        uuid;
  v_tasks_created      integer := 0;
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- ── Find next active, non-skipped step ──────────────────────────────────────
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
    UPDATE workflow_instances
    SET    status       = 'approved',
           updated_at   = now(),
           completed_at = now()
    WHERE  id = p_instance_id;

    INSERT INTO workflow_action_log (instance_id, actor_id, action, step_order, notes)
    VALUES (p_instance_id, auth.uid(), 'completed', v_instance.current_step,
            'All approval steps completed');

    PERFORM wf_queue_notification(
      p_instance_id, 'wf.completed', v_instance.submitted_by,
      jsonb_build_object('module_code', v_instance.module_code)
    );

    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');
    RETURN;
  END IF;

  -- Advance current_step pointer
  UPDATE workflow_instances
  SET    current_step = v_next_step.step_order,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- Compute SLA deadline
  v_due_at := CASE
    WHEN v_next_step.is_cc THEN NULL
    WHEN v_next_step.sla_hours IS NOT NULL
    THEN now() + (v_next_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ════════════════════════════════════════════════════════════════════════════
  -- ROLE TYPE — always fan out to all active holders
  -- (applies regardless of approval_mode: default first-wins, ALL_OF all-must)
  -- ════════════════════════════════════════════════════════════════════════════

  IF v_next_step.approver_type = 'ROLE' AND v_next_step.approver_role IS NOT NULL THEN

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

      -- Apply delegation per-holder
      SELECT delegate_id INTO v_delegate_id
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
          'approval_mode', v_next_step.approval_mode
        )
      );
    END LOOP;

    IF v_tasks_created = 0 THEN
      INSERT INTO workflow_action_log
        (instance_id, task_id, actor_id, action, step_order, notes)
      VALUES (p_instance_id, NULL, auth.uid(), 'step_removed',
              v_next_step.step_order,
              'ROLE step skipped: no active role holders (or all are the submitter)');

      PERFORM wf_advance_instance(p_instance_id);
      RETURN;
    END IF;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES (p_instance_id, NULL, auth.uid(), 'step_advanced',
            v_next_step.step_order,
            format('Role fan-out: %s task(s) created, mode=%s',
                   v_tasks_created,
                   COALESCE(v_next_step.approval_mode, 'auto')));
    RETURN;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════════
  -- ALL OTHER TYPES — single approver
  -- ════════════════════════════════════════════════════════════════════════════

  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance %',
                  v_next_step.step_order, p_instance_id;
    RETURN;
  END IF;

  -- Removal Rule 1: initiator-as-approver
  IF v_approver_id = v_instance.submitted_by THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  -- Removal Rule 2: consecutive duplicate approver
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
            'Step removed: same approver in next step (remove_duplicate_approver=true)';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_remove_reason IS NOT NULL THEN
    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES (p_instance_id, NULL, auth.uid(), 'step_removed',
            v_next_step.step_order, v_remove_reason);

    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  PERFORM wf_queue_notification(
    p_instance_id,
    COALESCE(
      (SELECT wnt.code FROM workflow_notification_templates wnt
       WHERE wnt.id = v_next_step.notification_template_id),
      'wf.task_assigned'
    ),
    v_approver_id,
    jsonb_build_object('step_name', v_next_step.name, 'module_code', v_instance.module_code)
  );

  -- CC step: auto-complete then advance
  IF v_next_step.is_cc THEN
    UPDATE workflow_tasks
    SET status = 'approved', acted_at = now(), notes = 'CC — auto-notified'
    WHERE id = v_new_task_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES (p_instance_id, v_new_task_id, auth.uid(), 'cc_notified',
            v_next_step.step_order, 'CC step — notification sent, auto-completed');

    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

END;
$$;

COMMENT ON FUNCTION wf_advance_instance(uuid) IS
  'Advances instance to next active non-skipped step. '
  'ROLE type always fans out to all active role holders (mig 204). '
  'approval_mode=ALL_OF: all holders must approve. '
  'approval_mode=NULL (default): first to approve wins, siblings cancelled. '
  'CC steps auto-complete. Removal Rules 1 & 2 apply to single-approver types only.';


-- ── 5. wf_approve ─────────────────────────────────────────────────────────────

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
  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to, t.status
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

  -- Mark this task approved
  UPDATE workflow_tasks
  SET    status = 'approved', notes = p_notes, acted_at = now()
  WHERE  id = p_task_id;

  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'approved', v_task.step_order, p_notes);

  -- Read approval_mode from the step
  SELECT ws.approval_mode INTO v_approval_mode
  FROM   workflow_steps ws
  WHERE  ws.id = v_task.step_id;

  IF v_approval_mode = 'ALL_OF' THEN
    -- Only advance when every sibling task is also approved
    SELECT COUNT(*) INTO v_pending_count
    FROM   workflow_tasks
    WHERE  instance_id = v_task.instance_id
      AND  step_order  = v_task.step_order
      AND  status      = 'pending'
      AND  id         != p_task_id;

    IF v_pending_count = 0 THEN
      PERFORM wf_advance_instance(v_task.instance_id);
    END IF;
    -- Otherwise wait for remaining approvers

  ELSE
    -- Default (NULL): cancel any sibling tasks (ROLE fan-out), then advance.
    -- For single-person steps there are no siblings — UPDATE affects 0 rows.
    UPDATE workflow_tasks
    SET    status   = 'cancelled',
           acted_at = now(),
           notes    = 'Cancelled: another approver approved first'
    WHERE  instance_id = v_task.instance_id
      AND  step_order  = v_task.step_order
      AND  status      = 'pending'
      AND  id         != p_task_id;

    PERFORM wf_advance_instance(v_task.instance_id);
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_approve(uuid, text) IS
  'Approves a pending workflow task. '
  'ALL_OF (mig 204): advances only when all sibling tasks also approved. '
  'Default (NULL): cancels any sibling tasks, then advances immediately. '
  'Callable by assigned approver or admin / workflow.admin.';


-- ── 6. get_workflow_participants — remove coApprovers subquery ────────────────

DROP FUNCTION IF EXISTS get_workflow_participants(text);
DROP FUNCTION IF EXISTS get_workflow_participants(text, uuid);

CREATE OR REPLACE FUNCTION get_workflow_participants(
  p_module_code text,
  p_profile_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_id uuid;
  v_today       date := current_date;
  v_result      jsonb;
BEGIN
  SELECT wf_template_id
  INTO   v_template_id
  FROM   workflow_assignments
  WHERE  module_code    = p_module_code
    AND  is_active      = true
    AND  effective_from <= v_today
    AND  (effective_to IS NULL OR effective_to >= v_today)
  LIMIT  1;

  IF v_template_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',    ws.step_order,
      'stepName',     ws.name,
      'approverType', ws.approver_type,
      'approverRole', ws.approver_role,
      'isCC',         COALESCE(ws.is_cc, false),
      'approvalMode', ws.approval_mode,   -- 'ALL_OF' | null

      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name, 'Dept. Head')
          WHEN 'ROLE'          THEN COALESCE(role_row.name, ws.approver_role)
          WHEN 'RULE_BASED'    THEN COALESCE(role_row.name, ws.approver_role, ws.name)
          WHEN 'SELF'          THEN COALESCE(self_emp.name, 'You')
          ELSE                      ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE'          THEN
            CASE WHEN ws.approval_mode = 'ALL_OF'
                 THEN 'All active members must approve'
                 ELSE 'All active members — first to approve wins'
            END
          WHEN 'SELF'          THEN NULL
          ELSE                      NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN true
          WHEN 'ROLE'          THEN true   -- always resolves (fan-out)
          WHEN 'MANAGER'       THEN (mgr_emp.name IS NOT NULL)
          WHEN 'DEPT_HEAD'     THEN (mgr_emp.name IS NOT NULL)
          WHEN 'SELF'          THEN (self_emp.name IS NOT NULL)
          ELSE                      false
        END,

      -- coApprovers deprecated by mig 204; always null
      'coApprovers', NULL::jsonb
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles pr
    JOIN   employees emp ON emp.id = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code = ws.approver_role AND r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type IN ('ROLE', 'RULE_BASED')

  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
           AND p_profile_id IS NOT NULL

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   profiles sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'
            AND p_profile_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_participants(text, uuid) IS
  'Returns routing chain for a module. '
  'ROLE steps: resolvedName = role name, resolvedDesignation describes fan-out semantics. '
  'coApprovers always null (deprecated by mig 204). '
  'approvalMode: ALL_OF = all members must approve; null = first wins.';


-- ── Verification ──────────────────────────────────────────────────────────────

-- No ANY_OF rows should remain
SELECT COUNT(*) AS any_of_remaining
FROM   workflow_steps
WHERE  approval_mode = 'ANY_OF';
-- Expected: 0

-- workflow_step_approvers should be empty
SELECT COUNT(*) AS orphan_rows
FROM   workflow_step_approvers;
-- Expected: 0

-- =============================================================================
-- END OF MIGRATION 204
-- =============================================================================
