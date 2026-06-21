-- =============================================================================
-- Migration 215: Re-apply wf_force_advance with legacy ROLE fan-out
--
-- WHY THIS EXISTS
-- ───────────────
-- Migration 208 rewrote wf_force_advance to fan out ROLE steps. However the
-- version that was actually pushed to the database (via `supabase db push`)
-- was an older DRAFT of mig 208 that still used wf_resolve_approver() in the
-- legacy path — returning only ONE approver instead of all role holders.
--
-- The mig 208 file on disk was subsequently corrected, but because
-- supabase_migrations.schema_migrations already records version 20260513208
-- as applied, `db push` skips it. A new migration is required to re-apply
-- the correct function body.
--
-- SYMPTOM
-- ───────
-- Force-advancing WF-20260513-3B274C to the Finance step (step_order=2,
-- approver_type='ROLE', approver_role='finance', approval_mode IS NULL)
-- created a task only for Hari A. Naveen Elango — also an active Finance
-- role holder — received no task.
--
-- FIX
-- ───
-- This migration is identical to the corrected mig 208 file. It replaces
-- the function currently live in the database with the version that properly
-- handles the legacy ROLE fan-out.
--
-- No schema changes are made — only the function body is replaced.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_force_advance(
  p_instance_id       uuid,
  p_target_step_order integer,
  p_reason            text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance        RECORD;
  v_target_step     RECORD;
  v_co              RECORD;
  v_approver_id     uuid;
  v_delegate_id     uuid;
  v_role_holder_id  uuid;
  v_due_at          timestamptz;
  v_new_task_id     uuid;
  v_first_task_id   uuid;          -- first task created (audit log FK)
  v_all_task_ids    uuid[] := '{}'; -- all tasks created (Gap 3)
  v_tasks_created   integer := 0;
  v_task            RECORD;
BEGIN
  -- ── Access check ────────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_force_advance: insufficient permissions';
  END IF;

  -- ── Reason is mandatory ──────────────────────────────────────────────────────
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_force_advance: reason is required';
  END IF;

  -- ── Load and lock instance ───────────────────────────────────────────────────
  SELECT id, template_id, current_step, metadata,
         submitted_by, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_force_advance: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_force_advance: instance is not active (status: %)',
                    v_instance.status;
  END IF;

  IF p_target_step_order <= v_instance.current_step THEN
    RAISE EXCEPTION
      'wf_force_advance: target step % must be after current step %',
      p_target_step_order, v_instance.current_step;
  END IF;

  -- ── Validate target step ─────────────────────────────────────────────────────
  SELECT ws.*
  INTO   v_target_step
  FROM   workflow_steps ws
  WHERE  ws.template_id = v_instance.template_id
    AND  ws.step_order  = p_target_step_order
    AND  ws.is_active   = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_force_advance: step % not found or inactive',
                    p_target_step_order;
  END IF;

  -- ── Mark all pending tasks before target as force_advanced ───────────────────
  FOR v_task IN
    SELECT wt.id, wt.assigned_to, wt.step_order
    FROM   workflow_tasks wt
    WHERE  wt.instance_id = p_instance_id
      AND  wt.status      = 'pending'
      AND  wt.step_order  < p_target_step_order
    FOR UPDATE
  LOOP
    UPDATE workflow_tasks
    SET    status   = 'force_advanced',
           notes    = p_reason,
           acted_at = now()
    WHERE  id = v_task.id;

    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.task_removed',
      v_task.assigned_to,
      jsonb_build_object(
        'step_order', v_task.step_order,
        'reason',     p_reason
      )
    );
  END LOOP;

  -- ── Advance instance to target step ─────────────────────────────────────────
  -- Done early so SLA timestamps and audit entries are consistent.
  -- If Gap-2 exception fires below, this UPDATE is rolled back automatically.
  UPDATE workflow_instances
  SET    current_step = p_target_step_order,
         status       = 'in_progress',
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Compute SLA deadline ────────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_target_step.sla_hours IS NOT NULL
    THEN now() + (v_target_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create tasks for target step ─────────────────────────────────────────────
  --
  --   Multi-approver step (approval_mode IS NOT NULL):
  --     Mirrors mig-203 fan-out: iterate workflow_step_approvers; ROLE entries
  --     fan out to ALL active holders; other types use wf_resolve_approver_ex.
  --
  --   Legacy single-approver step (approval_mode IS NULL):
  --     ROLE type  → fan out to ALL active role holders (mig 215 fix)
  --     Other types → wf_resolve_approver() — unchanged behaviour
  --
  IF v_target_step.approval_mode IS NOT NULL THEN

    -- ── Multi-approver path ───────────────────────────────────────────────────
    FOR v_co IN
      SELECT *
      FROM   workflow_step_approvers
      WHERE  step_id  = v_target_step.id
      ORDER  BY sort_order
    LOOP

      -- CC entries: notify only, no task
      IF v_co.is_cc THEN
        v_approver_id := wf_resolve_approver_ex(
          v_co.approver_type,
          v_co.approver_role,
          v_co.approver_profile_id,
          v_instance.template_id,
          p_instance_id
        );
        IF v_approver_id IS NOT NULL THEN
          PERFORM wf_queue_notification(
            p_instance_id, 'wf.task_assigned', v_approver_id,
            jsonb_build_object(
              'step_name',   v_target_step.name,
              'module_code', v_instance.module_code,
              'is_cc',       true
            )
          );
        END IF;
        CONTINUE;
      END IF;

      IF v_co.approver_type = 'ROLE' AND v_co.approver_role IS NOT NULL THEN

        -- ROLE fan-out: one task per active role holder (same as mig 203)
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

          -- Resolve delegation for this holder
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
            (p_instance_id, v_target_step.id, v_target_step.step_order,
             v_approver_id, v_due_at)
          RETURNING id INTO v_new_task_id;

          v_tasks_created  := v_tasks_created + 1;
          v_all_task_ids   := array_append(v_all_task_ids, v_new_task_id);
          IF v_first_task_id IS NULL THEN v_first_task_id := v_new_task_id; END IF;

          PERFORM wf_queue_notification(
            p_instance_id, 'wf.task_assigned', v_approver_id,
            jsonb_build_object(
              'step_name',     v_target_step.name,
              'module_code',   v_instance.module_code,
              'approval_mode', v_target_step.approval_mode,
              'role_code',     v_co.approver_role
            )
          );
        END LOOP;

      ELSE

        -- Non-ROLE approver (SPECIFIC_USER, MANAGER, DEPT_HEAD, SELF)
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
          (p_instance_id, v_target_step.id, v_target_step.step_order,
           v_approver_id, v_due_at)
        RETURNING id INTO v_new_task_id;

        v_tasks_created  := v_tasks_created + 1;
        v_all_task_ids   := array_append(v_all_task_ids, v_new_task_id);
        IF v_first_task_id IS NULL THEN v_first_task_id := v_new_task_id; END IF;

        PERFORM wf_queue_notification(
          p_instance_id, 'wf.task_assigned', v_approver_id,
          jsonb_build_object(
            'step_name',     v_target_step.name,
            'module_code',   v_instance.module_code,
            'approval_mode', v_target_step.approval_mode
          )
        );

      END IF;

    END LOOP; -- co-approvers loop

  ELSE

    -- ── Legacy single-approver path (approval_mode IS NULL) ───────────────────
    --
    -- These steps pre-date the multi-approver schema (mig 200). They store
    -- approver_type / approver_role directly on workflow_steps, with no rows
    -- in workflow_step_approvers.
    --
    -- ROLE type still needs fan-out (mig 215 fix): iterate all active role
    -- holders exactly like the multi-approver path above.
    -- All other types (MANAGER, DEPT_HEAD, SELF, SPECIFIC_USER) resolve to a
    -- single approver via wf_resolve_approver — unchanged behaviour.

    IF v_target_step.approver_type = 'ROLE'
       AND v_target_step.approver_role IS NOT NULL THEN

      -- Legacy ROLE fan-out
      FOR v_role_holder_id IN
        SELECT ur.profile_id
        FROM   user_roles ur
        JOIN   roles r ON r.id = ur.role_id
        WHERE  r.code       = v_target_step.approver_role
          AND  r.active     = true
          AND  ur.is_active = true
          AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
      LOOP
        CONTINUE WHEN v_role_holder_id = v_instance.submitted_by;

        -- Resolve delegation for this holder
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
          (p_instance_id, v_target_step.id, v_target_step.step_order,
           v_approver_id, v_due_at)
        RETURNING id INTO v_new_task_id;

        v_tasks_created  := v_tasks_created + 1;
        v_all_task_ids   := array_append(v_all_task_ids, v_new_task_id);
        IF v_first_task_id IS NULL THEN v_first_task_id := v_new_task_id; END IF;

        PERFORM wf_queue_notification(
          p_instance_id, 'wf.task_assigned', v_approver_id,
          jsonb_build_object(
            'step_name',   v_target_step.name,
            'module_code', v_instance.module_code,
            'role_code',   v_target_step.approver_role
          )
        );
      END LOOP;

    ELSE

      -- Legacy non-ROLE: single approver via wf_resolve_approver (unchanged)
      v_approver_id := wf_resolve_approver(v_target_step.id, p_instance_id);

      IF v_approver_id IS NOT NULL AND v_approver_id != v_instance.submitted_by THEN
        INSERT INTO workflow_tasks
          (instance_id, step_id, step_order, assigned_to, due_at)
        VALUES
          (p_instance_id, v_target_step.id, v_target_step.step_order,
           v_approver_id, v_due_at)
        RETURNING id INTO v_new_task_id;

        v_tasks_created  := 1;
        v_first_task_id  := v_new_task_id;
        v_all_task_ids   := ARRAY[v_new_task_id];

        PERFORM wf_queue_notification(
          p_instance_id, 'wf.task_assigned', v_approver_id,
          jsonb_build_object(
            'step_name',   v_target_step.name,
            'module_code', v_instance.module_code
          )
        );
      END IF;

    END IF; -- ROLE vs non-ROLE legacy

  END IF; -- multi-approver vs legacy

  -- ── Gap 2: Fail fast if no tasks were created ────────────────────────────────
  IF v_tasks_created = 0 THEN
    RAISE EXCEPTION
      'wf_force_advance: step % has no valid approvers — '
      'the role may have no active members, or all members are the submitter. '
      'Cannot force-advance to a step with no assignable approver.',
      p_target_step_order;
  END IF;

  -- ── Audit log ─────────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    p_instance_id,
    v_first_task_id,
    auth.uid(),
    'force_advanced',
    p_target_step_order,
    p_reason,
    jsonb_build_object(
      'from_step',     v_instance.current_step,
      'to_step',       p_target_step_order,
      'reason',        p_reason,
      'tasks_created', v_tasks_created,
      'task_ids',      to_jsonb(v_all_task_ids),
      'new_task_id',   v_first_task_id
    )
  );

  -- ── Notify submitter ───────────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.force_advanced',
    v_instance.submitted_by,
    jsonb_build_object(
      'step_name', v_target_step.name,
      'reason',    p_reason
    )
  );
END;
$$;

COMMENT ON FUNCTION wf_force_advance(uuid, integer, text) IS
  'Admin-only: skip the current pending step(s) and advance the instance to a '
  'chosen future step. Bypassed tasks are marked force_advanced. '
  'Reason is mandatory. Full audit trail written. '
  'Multi-approver ROLE steps fan out to ALL active role holders (mig 208). '
  'Legacy single-approver ROLE steps also fan out to ALL active role holders '
  '(mig 215 fix — the mig 208 draft that was pushed had this path missing). '
  'Legacy non-ROLE steps use wf_resolve_approver (unchanged). '
  'Gap 2: RAISE EXCEPTION if no tasks can be created — rolls back the entire '
  'operation so the instance is left untouched. '
  'Gap 3: audit log metadata includes task_ids[] (all created tasks) in '
  'addition to task_id FK (first task, backward-compat).';

REVOKE ALL    ON FUNCTION wf_force_advance(uuid, integer, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION wf_force_advance(uuid, integer, text) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 215
--
-- To verify after applying:
--   1. Force-advance a new workflow to a legacy ROLE step (approval_mode IS NULL)
--      → ALL active role holders should receive tasks (not just one)
--   2. Force-advance to a step whose only approver is the submitter → EXCEPTION
--      raised, instance untouched, bypassed tasks still pending
--   3. Audit log metadata.task_ids contains all created task UUIDs
-- =============================================================================
