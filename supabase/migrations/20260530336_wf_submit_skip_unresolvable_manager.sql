-- =============================================================================
-- Migration 336 — wf_submit: skip MANAGER/DEPT_HEAD steps when no approver
-- =============================================================================
--
-- PROBLEM
-- ───────
-- wf_submit resolves the approver for the first step and raises an exception
-- if the result is NULL:
--   "wf_submit: cannot resolve approver for step 1 of template PERSONAL_INFO_EDIT"
--
-- For MANAGER / DEPT_HEAD steps this is a legitimate org-structure gap —
-- the submitter has no manager. The step should be skipped so the workflow
-- can proceed to the next approver (e.g. a ROLE step).
--
-- For ROLE / SPECIFIC_USER / RULE_BASED steps a NULL result is a configuration
-- error and should still raise an exception.
--
-- CHANGE
-- ──────
-- wf_submit is updated to:
--   1. Create the instance as before (step resolution requires the instance_id
--      for delegation lookups).
--   2. Walk through all active, non-condition-skipped steps in order.
--      For each:
--        a. Try wf_resolve_approver.
--        b. If NULL AND approver_type IN ('MANAGER','DEPT_HEAD') → log an
--           'auto_skipped' entry in workflow_action_log and continue.
--        c. If NULL AND any other type → RAISE EXCEPTION (config error).
--        d. If non-NULL → this is the first assignable step; proceed.
--   3. If no assignable step is found after the walk, RAISE EXCEPTION.
--
-- SCOPE
-- ─────
-- Only wf_submit is changed. wf_advance_instance (mid-flow advancement) is
-- unchanged — it already handles NULL approvers with a WARNING + stall, which
-- is the existing behavior for mid-workflow gaps.
--
-- EXISTING BEHAVIOUR PRESERVED
-- ─────────────────────────────
-- • ROLE / SPECIFIC_USER / RULE_BASED NULL → still raises exception.
-- • wf_evaluate_skip_step (condition-based skip) → still respected, unchanged.
-- • wf_advance_instance → untouched.
-- • All other wf_* functions → untouched.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb DEFAULT '{}'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template      RECORD;
  v_instance_id   uuid;
  v_task_id       uuid;
  v_approver_id   uuid;
  v_due_at        timestamptz;
  v_step          RECORD;          -- current candidate step in the walk
  v_first_step    RECORD;          -- first non-condition-skip step (for instance seed)
  v_chosen_step   RECORD;          -- the step we'll actually assign to
BEGIN
  -- ── 1. Validate template ──────────────────────────────────────────────────
  SELECT id, version, module_code, is_active
  INTO   v_template
  FROM   workflow_templates
  WHERE  code      = p_template_code
    AND  is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_submit: template % not found or inactive', p_template_code;
  END IF;

  IF v_template.module_code != p_module_code THEN
    RAISE EXCEPTION 'wf_submit: module_code mismatch (template expects %, got %)',
                    v_template.module_code, p_module_code;
  END IF;

  -- ── 2. Guard: no concurrent active workflow ───────────────────────────────
  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      = 'in_progress'
  ) THEN
    RAISE EXCEPTION 'wf_submit: an active workflow already exists for this record';
  END IF;

  -- ── 3. Find first non-condition-skip step (for instance seed) ────────────
  -- We need at least one candidate step to exist before creating the instance.
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

  -- ── 4. Create instance (seeded with first candidate step; updated below) ──
  INSERT INTO workflow_instances
    (template_id, template_version, module_code, record_id,
     submitted_by, current_step, status, metadata)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata)
  RETURNING id INTO v_instance_id;

  -- ── 5. Walk steps to find the first one with a resolvable approver ────────
  --
  -- For each step (in step_order):
  --   • Skip if wf_evaluate_skip_step says to (condition-based skip, unchanged).
  --   • Resolve approver. If NULL:
  --       - MANAGER / DEPT_HEAD → log 'auto_skipped', continue to next step.
  --       - Any other type      → raise exception (config error).
  --   • Non-NULL → this is our chosen step.

  FOR v_step IN
    SELECT ws.*, ws.approver_type   -- include approver_type for the null check
    FROM   workflow_steps ws
    WHERE  ws.template_id = v_template.id
      AND  ws.is_active   = true
      AND  NOT wf_evaluate_skip_step(ws.id, p_metadata)
    ORDER  BY ws.step_order
  LOOP
    v_approver_id := wf_resolve_approver(v_step.id, v_instance_id);

    IF v_approver_id IS NULL THEN
      IF v_step.approver_type IN ('MANAGER', 'DEPT_HEAD') THEN
        -- Org-structure gap — skip this step silently and log it.
        INSERT INTO workflow_action_log
          (instance_id, task_id, actor_id, action, step_order, notes, metadata)
        VALUES
          (v_instance_id, NULL, auth.uid(), 'auto_skipped', v_step.step_order,
           'No ' || v_step.approver_type || ' found — step skipped automatically.',
           jsonb_build_object('template_code', p_template_code,
                              'approver_type', v_step.approver_type));
        CONTINUE;   -- try next step
      ELSE
        -- Config error: ROLE / SPECIFIC_USER / RULE_BASED must be resolvable.
        RAISE EXCEPTION
          'wf_submit: cannot resolve approver for step % (type=%) of template %',
          v_step.step_order, v_step.approver_type, p_template_code;
      END IF;
    END IF;

    -- Non-NULL approver found — this is our chosen step.
    v_chosen_step := v_step;
    EXIT;   -- stop walking
  END LOOP;

  IF v_chosen_step IS NULL THEN
    RAISE EXCEPTION
      'wf_submit: no resolvable approver found for any step in template % '
      '(all MANAGER/DEPT_HEAD steps had no assigned person)',
      p_template_code;
  END IF;

  -- ── 6. Update instance current_step to the chosen step ───────────────────
  -- (May differ from v_first_step if early steps were auto-skipped.)
  UPDATE workflow_instances
  SET    current_step = v_chosen_step.step_order,
         updated_at   = now()
  WHERE  id = v_instance_id;

  -- ── 7. SLA deadline ───────────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_chosen_step.sla_hours IS NOT NULL
    THEN now() + (v_chosen_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── 8. Create first task ──────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_instance_id, v_chosen_step.id, v_chosen_step.step_order,
     v_approver_id, v_due_at)
  RETURNING id INTO v_task_id;

  -- ── 9. Audit log ──────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, metadata)
  VALUES
    (v_instance_id, v_task_id, auth.uid(), 'submitted', v_chosen_step.step_order,
     jsonb_build_object('template_code', p_template_code));

  -- ── 10. Notify first approver ─────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_instance_id,
    'wf.task_assigned',
    v_approver_id,
    jsonb_build_object(
      'step_name',   v_chosen_step.name,
      'module_code', p_module_code
    )
  );

  -- ── 11. Sync module status ────────────────────────────────────────────────
  PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Start a new workflow instance. Walks steps in order; auto-skips MANAGER and '
  'DEPT_HEAD steps when no approver is found in the org structure (logs each '
  'skipped step as auto_skipped in workflow_action_log). Raises exception for '
  'ROLE/SPECIFIC_USER/RULE_BASED steps that cannot be resolved — those are '
  'configuration errors. Mig 336: auto-skip unresolvable org-structure steps.';
