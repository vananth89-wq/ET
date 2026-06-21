-- =============================================================================
-- Migration 493 — Termination Module: Workflow Integration (Phase 3)
--
-- Two changes to existing workflow engine functions:
--
-- 1. wf_submit — concurrent termination guard (§4.2)
--    Block any non-termination wf_submit call when the target employee has
--    a PENDING termination. Target derivation:
--      • employee_hire  → p_record_id IS employees.id
--      • all others     → caller's employee (get_my_employee_id())
--    This covers the primary cases: SELF submissions are always the caller's
--    employee; HR-initiated hire is the hire target. Profile change requests
--    submitted by HR on behalf of a third employee are an edge case handled
--    at the UI layer (TerminationImpactModal shows the pending state).
--
-- 2. wf_sync_module_status — termination branch (§4.3)
--    Called by wf_submit ('submitted'), wf_advance_instance ('approved'),
--    workflow task approval ('approved'/'rejected'), and wf_withdraw ('draft').
--    Note: wf_withdraw passes 'draft' not 'withdrawn'.
--    Record type (termination vs reversal) is detected by checking which
--    table p_record_id belongs to — both share module_code 'termination'.
--
-- Design spec: docs/termination-design.md §4.2, §4.3
-- Predecessor: 20260604492
-- Next: 20260604494 (Phase 4 — Edge Functions)
-- =============================================================================


-- =============================================================================
-- 1. wf_submit — add concurrent termination guard
--    Source: mig 480 (authoritative version). One block added after the
--    existing "active workflow already exists" guard.
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
  -- Concurrent termination guard (mig 493)
  v_guard_emp_id        uuid;
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

  -- ── Concurrent termination guard (mig 493 — §4.2) ────────────────────────
  -- Block all non-termination submissions when a PENDING termination exists
  -- for the target employee.
  IF p_module_code <> 'termination' THEN
    -- Derive target employee from context
    IF p_module_code = 'employee_hire' THEN
      v_guard_emp_id := p_record_id;   -- p_record_id IS employees.id for hire
    ELSE
      SELECT employee_id INTO v_guard_emp_id
      FROM   profiles WHERE id = auth.uid();
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
  -- ── end concurrent guard ──────────────────────────────────────────────────

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

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb, text) IS
  'Mig 338: MANAGER/DEPT_HEAD auto-skip. '
  'Mig 480: ROLE step auto-skip when all members are the submitter. '
  'Mig 493: concurrent termination guard — blocks non-termination submissions '
  'when a PENDING termination exists for the target employee.';


-- =============================================================================
-- 2. wf_sync_module_status — add termination branch
--    Source: mig 269 (authoritative version).
--
--    Status mapping from workflow engine → employee_terminations.workflow_status:
--      'submitted'   → no-op   (submit_termination already set PENDING)
--      'in_progress' → no-op
--      'approved'    → APPROVED (+ REVERSED on original for reversals)
--      'rejected'    → REJECTED
--      'draft'       → WITHDRAWN  ← wf_withdraw passes 'draft', not 'withdrawn'
--      'withdrawn'   → WITHDRAWN  (belt-and-suspenders)
--      'cancelled'   → WITHDRAWN
--
--    Record type detection: both terminations and reversals share module_code
--    'termination'. Detect by checking which table owns p_record_id.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id    uuid;
  v_termination_id uuid;
BEGIN

  -- ── Expense Reports ────────────────────────────────────────────────────────
  IF p_module_code = 'expense_reports' THEN

    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles WHERE id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()         ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Profile change modules ─────────────────────────────────────────────────
  ELSIF p_module_code LIKE 'profile_%' THEN

    UPDATE workflow_pending_changes
    SET
      status =
        CASE p_status
          WHEN 'submitted'   THEN 'pending'
          WHEN 'in_progress' THEN 'pending'
          WHEN 'draft'       THEN 'withdrawn'
          WHEN 'cancelled'   THEN 'withdrawn'
          WHEN 'approved'    THEN 'approved'
          WHEN 'rejected'    THEN 'rejected'
          WHEN 'withdrawn'   THEN 'withdrawn'
          ELSE status
        END,
      resolved_at =
        CASE
          WHEN p_status IN ('approved', 'rejected', 'draft', 'withdrawn', 'cancelled')
          THEN now()
          ELSE NULL
        END
    WHERE id = p_record_id;

  -- ── Employee Hire ──────────────────────────────────────────────────────────
  ELSIF p_module_code = 'employee_hire' THEN

    IF p_status = 'approved' THEN
      PERFORM wf_activate_employee(p_record_id);

    ELSIF p_status = 'submitted' THEN
      UPDATE employees
      SET    status     = 'Pending',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'rejected' THEN
      UPDATE employees
      SET    status     = 'Rejected',
             locked     = true,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'awaiting_clarification' THEN
      UPDATE employees
      SET    status     = 'Incomplete',
             locked     = false,
             updated_at = now()
      WHERE  id = p_record_id;

    ELSIF p_status = 'draft' THEN
      UPDATE employees
      SET    deleted_at = now(),
             updated_at = now()
      WHERE  id      = p_record_id
        AND  status != 'Active';

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: unhandled status % for employee_hire — record unchanged',
        p_status;
    END IF;

  -- ── Termination (terminations + reversals share this module_code) ──────────
  ELSIF p_module_code = 'termination' THEN

    -- Detect whether p_record_id is a termination or a reversal
    IF EXISTS (SELECT 1 FROM employee_terminations WHERE id = p_record_id) THEN

      -- ── TERMINATION record ──────────────────────────────────────────────────
      IF p_status = 'approved' THEN
        UPDATE employee_terminations
        SET    workflow_status = 'APPROVED',
               approved_at    = now(),
               approved_by    = auth.uid(),
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;
        -- Post-approval automation (slice closure, employees.status flip)
        -- is handled by the apply_termination_approval Edge Function (Phase 4).
        -- For same-day / past-dated: Edge Function fires on approval event.
        -- For future-dated: daily process_scheduled_terminations Edge Function.

      ELSIF p_status = 'rejected' THEN
        UPDATE employee_terminations
        SET    workflow_status = 'REJECTED',
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;

      ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
        -- wf_withdraw passes 'draft'; explicit 'withdrawn'/'cancelled' also handled
        UPDATE employee_terminations
        SET    workflow_status      = 'WITHDRAWN',
               workflow_instance_id = NULL,
               updated_at           = now(),
               updated_by           = auth.uid()
        WHERE  id = p_record_id;

      -- 'submitted' / 'in_progress': no-op — submit_termination already set PENDING
      END IF;

    ELSIF EXISTS (SELECT 1 FROM employee_termination_reversals WHERE id = p_record_id) THEN

      -- ── REVERSAL record ────────────────────────────────────────────────────
      IF p_status = 'approved' THEN
        -- Approve the reversal
        UPDATE employee_termination_reversals
        SET    workflow_status = 'APPROVED',
               approved_at    = now(),
               approved_by    = auth.uid(),
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;

        -- Flip the original termination to REVERSED (unlocks partial unique index)
        UPDATE employee_terminations
        SET    workflow_status = 'REVERSED',
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = (
          SELECT termination_id
          FROM   employee_termination_reversals
          WHERE  id = p_record_id
        );
        -- Post-approval: apply_termination_reversal Edge Function (Phase 4)
        -- handles slice reopening + employees.status → Active.

      ELSIF p_status = 'rejected' THEN
        UPDATE employee_termination_reversals
        SET    workflow_status = 'REJECTED',
               updated_at     = now(),
               updated_by     = auth.uid()
        WHERE  id = p_record_id;

      ELSIF p_status IN ('draft', 'withdrawn', 'cancelled') THEN
        UPDATE employee_termination_reversals
        SET    workflow_status      = 'WITHDRAWN',
               workflow_instance_id = NULL,
               updated_at           = now(),
               updated_by           = auth.uid()
        WHERE  id = p_record_id;

      END IF;

    ELSE
      RAISE NOTICE
        'wf_sync_module_status: termination record % not found in either table — skipping',
        p_record_id;
    END IF;

  -- ── Unknown module ─────────────────────────────────────────────────────────
  ELSE
    RAISE NOTICE
      'wf_sync_module_status: unknown module_code %, record unchanged',
      p_module_code;
  END IF;

END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Dispatches workflow lifecycle events to module-specific record updates. '
  'Mig 245: extended for profile_ modules. '
  'Mig 269: added employee_hire branch (rejected, awaiting_clarification, draft). '
  'Mig 493: added termination branch. Detects termination vs reversal by table lookup. '
  'wf_withdraw passes status=''draft'' — mapped to WITHDRAWN on termination rows.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm concurrent guard is present in wf_submit
SELECT prosrc LIKE '%concurrent termination guard%' AS has_guard
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'wf_submit';
-- Expect: true

-- Confirm termination branch is present in wf_sync_module_status
SELECT prosrc LIKE '%employee_termination_reversals%' AS has_termination_branch
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'wf_sync_module_status';
-- Expect: true

-- =============================================================================
-- END OF MIGRATION 493
-- =============================================================================
