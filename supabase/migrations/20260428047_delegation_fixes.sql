-- =============================================================================
-- Delegation Fixes
--
-- Gap 1 — enforce allow_delegation flag on workflow_steps
--   wf_resolve_approver previously ignored the allow_delegation column.
--   Now skips delegation lookup when the step has allow_delegation = false.
--
-- Gap 2 — chain delegation following
--   Previously only one level was followed (A→B, stopped there even if B→C).
--   Now follows the chain up to 5 hops, exiting when no further delegation
--   is found. This prevents infinite loops from misconfigured circular chains
--   while correctly handling legitimate multi-hop setups.
--
-- Gap 3 — wf_reassign applies delegation chain to new assignee
--   Manual task reassignment now also follows the delegation chain for the
--   new assignee (subject to the step's allow_delegation flag). This means
--   if an admin reassigns to X and X has an active delegation, the task
--   is routed to X's delegate instead.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Fix wf_resolve_approver (Gaps 1 & 2)
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_resolve_approver(
  p_step_id     uuid,
  p_instance_id uuid
) RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_step             RECORD;
  v_instance         RECORD;
  v_submitter_emp    RECORD;
  v_approver         uuid;
  -- Chain delegation variables
  v_chain_depth      integer := 0;
  v_chain_max        CONSTANT integer := 5;   -- hard cap: no more than 5 hops
  v_next_delegate    uuid;
BEGIN
  -- ── Load step ──────────────────────────────────────────────────────────────
  SELECT approver_type, approver_role, approver_profile_id,
         template_id, allow_delegation
  INTO   v_step
  FROM   workflow_steps
  WHERE  id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: step % not found', p_step_id;
  END IF;

  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT submitted_by, metadata, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: instance % not found', p_instance_id;
  END IF;

  -- ── Submitter employee record ──────────────────────────────────────────────
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_submitter_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_instance.submitted_by;

  -- ── Resolve by approver type ───────────────────────────────────────────────

  CASE v_step.approver_type

    WHEN 'MANAGER' THEN
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_submitter_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    WHEN 'ROLE' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      WHERE  r.code      = v_step.approver_role
        AND  ur.is_active = true
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
      v_approver := v_step.approver_profile_id;

    WHEN 'SELF' THEN
      -- Route back to the submitter.
      -- Delegation is NEVER applied to SELF steps — the submitter must action
      -- these themselves (e.g. acknowledgement / declaration steps).
      v_approver := v_instance.submitted_by;
      RETURN v_approver;   -- early return — skip all delegation logic below

    WHEN 'RULE_BASED' THEN
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id
      JOIN   workflow_step_conditions wsc
               ON wsc.step_id = p_step_id AND wsc.skip_step = false
      WHERE  r.code = wsc.value
        AND  ur.is_active = true
        AND  ur.profile_id != v_instance.submitted_by
      LIMIT  1;

      IF v_approver IS NULL THEN
        SELECT p.id INTO v_approver
        FROM   profiles p
        WHERE  p.employee_id = v_submitter_emp.manager_id
          AND  p.is_active   = true
        LIMIT  1;
      END IF;

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation chain (Gaps 1 & 2) ────────────────────────────────────
  --
  -- Only run when:
  --   • an approver was resolved (not NULL)
  --   • the step explicitly allows delegation (allow_delegation = true)
  --
  -- Chain logic: follow up to v_chain_max hops. Each iteration looks up
  -- whether the current v_approver has an active delegation for today.
  -- Exits as soon as no further delegation is found or the cap is reached.
  -- This correctly handles A→B→C chains while preventing infinite loops.

  IF v_approver IS NOT NULL AND v_step.allow_delegation = true THEN

    LOOP
      v_chain_depth := v_chain_depth + 1;
      EXIT WHEN v_chain_depth > v_chain_max;  -- hard cap: prevent infinite loops

      SELECT delegate_id INTO v_next_delegate
      FROM   workflow_delegations
      WHERE  delegator_id = v_approver
        AND  is_active    = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  (template_id IS NULL OR template_id = v_step.template_id)
      LIMIT  1;

      EXIT WHEN v_next_delegate IS NULL;       -- no further delegation: stop

      v_approver := v_next_delegate;           -- follow the chain one more hop
    END LOOP;

  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver(uuid, uuid) IS
  'Resolves the profile_id of the approver for a step in a given instance. '
  'Types: MANAGER, ROLE, DEPT_HEAD, SPECIFIC_USER, SELF, RULE_BASED. '
  'Respects allow_delegation flag on the step. '
  'Follows the delegation chain up to 5 hops to handle multi-level delegations. '
  'SELF steps always return the submitter — delegation is never applied. '
  'Returns NULL if no approver is found.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Fix wf_reassign (Gap 3)
--
-- After the admin specifies a new assignee (p_new_profile_id), apply the
-- same delegation chain logic used by wf_resolve_approver. If the new
-- assignee has an active delegation (and the step allows it), the task is
-- routed to their delegate instead.
--
-- This ensures a manual reassignment behaves consistently with automatic
-- routing — the task always ends up with whoever is currently "on seat".
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_reassign(
  p_task_id        uuid,
  p_new_profile_id uuid,
  p_reason         text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task               RECORD;
  v_new_task           uuid;
  v_step_allow_deleg   boolean;
  v_final_assignee     uuid;
  -- Chain delegation variables (mirrors wf_resolve_approver)
  v_chain_depth        integer := 0;
  v_chain_max          CONSTANT integer := 5;
  v_next_delegate      uuid;
BEGIN
  -- ── Load and lock the task ─────────────────────────────────────────────────
  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to,
         t.status, t.due_at
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reassign: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_reassign: only pending tasks can be reassigned (current: %)',
                    v_task.status;
  END IF;

  -- ── Look up the step's allow_delegation flag ───────────────────────────────
  SELECT allow_delegation INTO v_step_allow_deleg
  FROM   workflow_steps
  WHERE  id = v_task.step_id;

  -- Default to true if step not found (defensive)
  v_step_allow_deleg := COALESCE(v_step_allow_deleg, true);

  -- ── Resolve final assignee, following delegation chain if allowed ──────────
  v_final_assignee := p_new_profile_id;

  IF v_step_allow_deleg = true THEN
    LOOP
      v_chain_depth := v_chain_depth + 1;
      EXIT WHEN v_chain_depth > v_chain_max;

      SELECT delegate_id INTO v_next_delegate
      FROM   workflow_delegations
      WHERE  delegator_id = v_final_assignee
        AND  is_active    = true
        AND  CURRENT_DATE BETWEEN from_date AND to_date
        AND  template_id IS NULL    -- reassign applies to all-template delegations only
                                    -- (no template_id context available here)
      LIMIT  1;

      EXIT WHEN v_next_delegate IS NULL;

      v_final_assignee := v_next_delegate;
    END LOOP;
  END IF;

  -- ── Mark the current task as reassigned ────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'reassigned',
         acted_at = now(),
         notes    = COALESCE(p_reason, notes)
  WHERE  id = p_task_id;

  -- ── Log the reassignment ───────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes,
     metadata)
  VALUES (
    v_task.instance_id,
    p_task_id,
    auth.uid(),
    'reassigned',
    v_task.step_order,
    p_reason,
    jsonb_build_object(
      'from_profile', v_task.assigned_to,
      'to_profile',   p_new_profile_id,       -- intended recipient
      'final_assignee', v_final_assignee,      -- actual after delegation
      'delegation_applied', (v_final_assignee != p_new_profile_id)
    )
  );

  -- ── Create new task for the final assignee ─────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, status, due_at)
  VALUES (
    v_task.instance_id,
    v_task.step_id,
    v_task.step_order,
    v_final_assignee,
    'pending',
    v_task.due_at
  )
  RETURNING id INTO v_new_task;

  -- ── Notify the final assignee ──────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.task_assigned',
    v_final_assignee,
    jsonb_build_object('reassigned', true)
  );

END;
$$;

COMMENT ON FUNCTION wf_reassign(uuid, uuid, text) IS
  'Reassigns a pending task to a new approver. '
  'Applies the delegation chain (up to 5 hops) if the step allows delegation, '
  'so the task always ends up with whoever is currently "on seat". '
  'Logs the original intended recipient and the final assignee for audit trail. '
  'Only pending tasks can be reassigned.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname,
       prosrc LIKE '%v_chain_max%'   AS has_chain_cap,
       prosrc LIKE '%allow_delegation%' AS checks_allow_deleg
FROM   pg_proc
WHERE  proname IN ('wf_resolve_approver', 'wf_reassign')
ORDER BY proname;
