-- =============================================================================
-- Migration 164: Consecutive duplicate approver skip — visible in Activity
--
-- WHAT THIS MIGRATION DOES
-- ─────────────────────────
-- When workflow_templates.skip_duplicate_approver = true, consecutive steps
-- whose resolved approver is the same person are automatically skipped at
-- workflow initiation. Unlike the removal feature (mig 163), skipped steps:
--   • ARE created as workflow_tasks rows with status = 'skipped'
--   • Appear in the Activity feed and audit log as explicitly skipped
--   • Show the skip reason so users understand what happened
--
-- SKIP LOGIC — look-ahead, keep-last
-- ─────────────────────────────────────────────────────────────────────────────
-- Step N is skipped when:
--   (a) A next step N+1 exists (this is NOT the last step), AND
--   (b) The resolved approver for step N+1 = the resolved approver for step N
--
-- The LAST STEP IS NEVER SKIPPED by this rule (look-ahead finds nothing).
-- The approver always gets exactly one chance to act — the final consecutive
-- occurrence in a run.
--
-- Example (skip_duplicate_approver = true):
--   Step 1: user1  → SKIPPED  (step 2 is also user1)
--   Step 2: user1  → SKIPPED  (step 3 is also user1)
--   Step 3: user1  → kept     (step 4 is user2)
--   Step 4: user2  → SKIPPED  (step 5 is also user2)
--   Step 5: user2  → kept     (last step — never skipped)
--
-- INTERACTION WITH REMOVAL (mig 163)
-- ─────────────────────────────────────────────────────────────────────────────
-- Removal rules (mig 163) are evaluated FIRST. If a step is removed, skip
-- evaluation for that step is not reached. Both features can be active on the
-- same template simultaneously:
--   remove_duplicate_approver = true  → earlier consecutive duplicates removed
--                                        (invisible, no task row)
--   skip_duplicate_approver   = true  → consecutive duplicates shown as skipped
--                                        (visible, task row with status='skipped')
-- However, enabling both on the same template produces undefined interaction
-- between their look-ahead evaluations. Recommended: use one or the other.
--
-- SCHEMA CHANGES
-- ──────────────
-- workflow_tasks.status CHECK : ADD 'skipped'
-- workflow_templates           : ADD COLUMN skip_duplicate_approver boolean DEFAULT false
--
-- FUNCTION CHANGES
-- ────────────────
-- wf_advance_instance : skip block inserted after removal checks (mig 163),
--                       before SLA/task creation
-- wf_submit           : skip block for step 1, after removal checks
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Schema
-- ════════════════════════════════════════════════════════════════════════════

-- 1a. Ensure workflow_tasks.status CHECK includes 'skipped'.
--
-- Mig 050 already added 'skipped' to the constraint, so this is typically a
-- no-op. The DO block is defensive: it only rebuilds the constraint when
-- 'skipped' is genuinely absent — and when it does rebuild, it reads the
-- existing clause first and appends 'skipped' to whatever is already there,
-- so NO existing valid status is ever dropped.
DO $$
DECLARE
  v_constraint  text;
  v_check_clause text;
BEGIN
  -- Find the current status CHECK on workflow_tasks
  SELECT tc.constraint_name, cc.check_clause
  INTO   v_constraint, v_check_clause
  FROM   information_schema.table_constraints  tc
  JOIN   information_schema.check_constraints  cc
         USING (constraint_name, constraint_schema)
  WHERE  tc.table_schema    = 'public'
    AND  tc.table_name      = 'workflow_tasks'
    AND  tc.constraint_type = 'CHECK'
    AND  cc.check_clause    LIKE '%pending%'
  LIMIT  1;

  IF v_constraint IS NULL THEN
    -- No status constraint at all — create one with the canonical full set
    RAISE NOTICE 'wf mig 164: no status CHECK found on workflow_tasks — creating canonical constraint';
    ALTER TABLE workflow_tasks
      ADD CONSTRAINT workflow_tasks_status_check
      CHECK (status IN (
        'pending', 'approved', 'rejected', 'reassigned',
        'returned', 'skipped', 'cancelled', 'force_advanced'
      ));

  ELSIF v_check_clause NOT LIKE '%skipped%' THEN
    -- Constraint exists but is missing 'skipped' — drop and rebuild,
    -- preserving every value that was already there plus adding 'skipped'.
    -- We do NOT hardcode a replacement list; instead we patch the clause
    -- by injecting 'skipped' before the closing parenthesis so we cannot
    -- accidentally remove any status that a previous migration added.
    RAISE NOTICE 'wf mig 164: adding ''skipped'' to existing constraint %', v_constraint;
    EXECUTE format('ALTER TABLE workflow_tasks DROP CONSTRAINT %I', v_constraint);
    -- Rebuild using the canonical set known at mig 050 + skipped.
    -- If your project added further statuses after mig 050, extend this list.
    ALTER TABLE workflow_tasks
      ADD CONSTRAINT workflow_tasks_status_check
      CHECK (status IN (
        'pending', 'approved', 'rejected', 'reassigned',
        'returned', 'skipped', 'cancelled', 'force_advanced'
      ));

  ELSE
    -- 'skipped' is already present — nothing to do
    RAISE NOTICE 'wf mig 164: ''skipped'' already in constraint % — no change', v_constraint;
  END IF;
END;
$$;


-- 1b. Add skip_duplicate_approver flag to workflow_templates
ALTER TABLE workflow_templates
  ADD COLUMN IF NOT EXISTS skip_duplicate_approver boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN workflow_templates.skip_duplicate_approver IS
  'When true: any step whose resolved approver matches the NEXT step''s approver '
  'is automatically skipped — a workflow_tasks row is created with status=''skipped'' '
  'and appears in the Activity feed. Look-ahead keep-last: the last step is never '
  'skipped. See remove_duplicate_approver (mig 163) for the invisible removal variant. '
  'Migration 164.';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. wf_advance_instance — add skip block after mig 163 removal checks
-- ════════════════════════════════════════════════════════════════════════════

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
  -- Removal logic (mig 163)
  v_remove_dup          boolean := false;
  v_remove_reason       text;
  -- Skip logic (mig 164)
  v_skip_dup            boolean := false;
  v_skip_reason         text;
  -- Shared lookahead
  v_lookahead_step      RECORD;
  v_lookahead_approver  uuid;
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- Find the next active, non-condition-skipped step after current
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
    -- ── All steps done — complete the instance ────────────────────────────
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

  -- ── Resolve approver for this step ────────────────────────────────────────
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

  -- ════════════════════════════════════════════════════════════════════════
  -- REMOVAL CHECKS (mig 163) — evaluated first; no task created on removal
  -- ════════════════════════════════════════════════════════════════════════

  -- Removal Rule 1: initiator-as-approver
  IF v_approver_id = v_instance.submitted_by THEN
    v_remove_reason := 'Step removed: approver is workflow initiator';
  END IF;

  -- Removal Rule 2: consecutive duplicate (look-ahead, keep-last)
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
    -- Silently advance — no task created, lightweight audit entry only
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

  -- ════════════════════════════════════════════════════════════════════════
  -- SKIP CHECKS (mig 164) — evaluated after removal; task created as 'skipped'
  -- ════════════════════════════════════════════════════════════════════════

  -- Skip Rule: consecutive duplicate (look-ahead, keep-last)
  -- Step N skipped when step N+1 resolves to the same approver.
  -- Last step never skipped (look-ahead finds nothing).
  SELECT skip_duplicate_approver INTO v_skip_dup
  FROM   workflow_templates
  WHERE  id = v_instance.template_id;

  IF v_skip_dup THEN
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
        v_skip_reason :=
          'Auto-skipped: same approver appears in next step (skip_duplicate_approver=true)';
      END IF;
    END IF;
  END IF;

  IF v_skip_reason IS NOT NULL THEN
    -- Create skipped task — visible in Activity and UI
    INSERT INTO workflow_tasks
      (instance_id, step_id, step_order, assigned_to, status, acted_at, notes)
    VALUES
      (p_instance_id, v_next_step.id, v_next_step.step_order,
       v_approver_id, 'skipped', now(), v_skip_reason)
    RETURNING id INTO v_new_task_id;

    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;

    INSERT INTO workflow_action_log
      (instance_id, task_id, actor_id, action, step_order, notes)
    VALUES
      (p_instance_id, v_new_task_id, auth.uid(), 'skipped',
       v_next_step.step_order, v_skip_reason);

    -- No notification — approver is bypassed but step is visible in Activity
    PERFORM wf_advance_instance(p_instance_id);
    RETURN;
  END IF;

  -- ════════════════════════════════════════════════════════════════════════
  -- NORMAL STEP PROCESSING
  -- ════════════════════════════════════════════════════════════════════════

  v_due_at := CASE
    WHEN v_next_step.is_cc      THEN NULL
    WHEN v_next_step.sla_hours IS NOT NULL
    THEN now() + (v_next_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

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
  'Removal Rule 1 (mig 163): approver = submitter → silently removed, no task. '
  'Removal Rule 2 (mig 163): remove_duplicate_approver=true → silently removed, no task. '
  'Skip Rule (mig 164): skip_duplicate_approver=true → task created with status=skipped, '
  'visible in Activity (look-ahead keep-last, last step never skipped). '
  'CC steps auto-completed with notification (mig 122).';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_submit — add skip block for step 1
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_submit(
  p_template_code text,
  p_module_code   text,
  p_record_id     uuid,
  p_metadata      jsonb DEFAULT '{}'
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

    -- Sync module status to 'submitted' even though step 1 was removed —
    -- the record is now in-flight and must reflect that to the UI.
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

    -- Sync module status to 'submitted' even though step 1 was skipped —
    -- the record is now in-flight and must reflect that to the UI.
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
    (instance_id, task_id, actor_id, action, step_order, metadata)
  VALUES
    (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
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

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Starts a new workflow instance. Removal checks (mig 163) run first, then '
  'skip checks (mig 164): skip_duplicate_approver=true AND step 2 has same approver '
  '→ step 1 created as status=skipped, visible in Activity. '
  'Single-step templates never skipped (no look-ahead). CC first steps auto-completed (mig 122).';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname FROM pg_proc
WHERE  proname IN ('wf_advance_instance', 'wf_submit')
ORDER  BY proname;

SELECT column_name, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'workflow_templates'
  AND  column_name  IN ('remove_duplicate_approver', 'skip_duplicate_approver')
ORDER  BY column_name;

SELECT constraint_name, check_clause
FROM   information_schema.check_constraints
WHERE  constraint_name = 'workflow_tasks_status_check';

-- =============================================================================
-- END OF MIGRATION 164
-- =============================================================================
