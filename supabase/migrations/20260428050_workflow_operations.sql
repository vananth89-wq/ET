-- =============================================================================
-- Workflow Operations — Admin Control Tower
--
-- Enables the Admin → Workflow → Operations screen with system-wide visibility
-- and controlled intervention capabilities.
--
-- Changes:
--   1. Extend workflow_tasks.status CHECK  → adds 'force_advanced'
--   2. vw_wf_operations                   — pageable system-wide operations view
--   3. wf_force_advance()                 — admin skips to a target step
--   4. wf_admin_decline()                 — admin returns request to submitter
--   5. wf_reassign() updated              — also notifies OLD assignee on reassign
--   6. 3 new notification templates:
--        wf.task_removed  / wf.force_advanced / wf.admin_declined
--   7. Verification
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Extend workflow_tasks.status CHECK
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_tasks
  DROP CONSTRAINT IF EXISTS workflow_tasks_status_check;

ALTER TABLE workflow_tasks
  ADD CONSTRAINT workflow_tasks_status_check
  CHECK (status IN (
    'pending',          -- awaiting action
    'approved',         -- approved by assignee
    'rejected',         -- rejected by assignee
    'reassigned',       -- delegated to someone else
    'returned',         -- returned to previous step (migration 048)
    'skipped',          -- auto-skipped by condition
    'cancelled',        -- workflow withdrawn / cancelled
    'force_advanced'    -- admin skipped this step
  ));


-- ════════════════════════════════════════════════════════════════════════════
-- 2. vw_wf_operations — system-wide pending task view
--
-- Visible to: has_role('admin') OR has_permission('workflow.admin')
-- (enforced by existing RLS on workflow_tasks and workflow_instances)
--
-- SLA status logic:
--   normal   → no due_at set, OR due_at is in the future
--   overdue  → past due_at, but not yet 2× SLA window elapsed
--   critical → past due_at AND elapsed time exceeds 1× SLA window
--              (i.e. now > due_at + sla_hours)
-- ════════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS vw_wf_operations;

CREATE VIEW vw_wf_operations AS
SELECT
  -- Identity
  wt.id                                                               AS task_id,
  wi.id                                                               AS instance_id,

  -- Human-readable display ID: prefix + YYYYMMDD + 6-char UUID fragment
  upper(
    CASE wi.module_code
      WHEN 'expense_reports'  THEN 'EXP'
      WHEN 'leave_requests'   THEN 'LVE'
      WHEN 'travel_requests'  THEN 'TRV'
      WHEN 'purchase_orders'  THEN 'PO'
      ELSE 'WF'
    END
    || '-' || to_char(wi.created_at, 'YYYYMMDD')
    || '-' || upper(left(wi.id::text, 6))
  )                                                                   AS display_id,

  -- Template / module
  tpl.code                                                            AS template_code,
  tpl.name                                                            AS template_name,
  wi.module_code,
  wi.record_id,
  wi.status                                                           AS instance_status,

  -- Current step
  wt.step_order,
  ws.name                                                             AS step_name,
  ws.sla_hours,

  -- Assignee (current approver blocking the workflow)
  wt.assigned_to                                                      AS assignee_id,
  assignee_emp.name                                                   AS assignee_name,
  assignee_emp.job_title                                              AS assignee_job_title,

  -- Submitter
  wi.submitted_by                                                     AS submitter_id,
  submitter_emp.name                                                  AS submitter_name,

  -- Department (submitter's department)
  dept.id                                                             AS department_id,
  dept.name                                                           AS department_name,

  -- Timing
  wi.created_at                                                       AS submitted_at,
  wt.created_at                                                       AS pending_since,
  wt.due_at,

  -- Age of the current pending task
  ROUND(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 3600, 1
  )                                                                   AS age_hours,
  FLOOR(
    EXTRACT(EPOCH FROM (now() - wt.created_at)) / 86400
  )::integer                                                          AS age_days,

  -- SLA classification
  CASE
    WHEN wt.due_at IS NULL OR wt.due_at > now()
      THEN 'normal'
    WHEN ws.sla_hours IS NOT NULL
     AND now() >= wt.due_at + (ws.sla_hours * interval '1 hour')
      THEN 'critical'
    ELSE 'overdue'
  END                                                                 AS sla_status

FROM       workflow_tasks      wt
JOIN       workflow_instances  wi          ON wi.id  = wt.instance_id
JOIN       workflow_steps      ws          ON ws.id  = wt.step_id
JOIN       workflow_templates  tpl         ON tpl.id = wi.template_id
JOIN       profiles            assignee_p  ON assignee_p.id = wt.assigned_to
JOIN       employees           assignee_emp ON assignee_emp.id = assignee_p.employee_id
JOIN       profiles            submitter_p ON submitter_p.id = wi.submitted_by
JOIN       employees           submitter_emp ON submitter_emp.id = submitter_p.employee_id
LEFT JOIN  departments         dept        ON dept.id = submitter_emp.dept_id

WHERE wt.status     = 'pending'
  AND wi.status     IN ('in_progress', 'awaiting_clarification');

COMMENT ON VIEW vw_wf_operations IS
  'System-wide view of all active pending workflow tasks. '
  'Readable by admin / workflow.admin only (enforced via table RLS). '
  'Includes computed age, SLA status (normal/overdue/critical), and display ID.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_force_advance()
--
-- Admin skips the current pending step(s) and jumps the instance to a chosen
-- future step. All pending tasks before the target are marked 'force_advanced'.
-- The admin must provide a reason (mandatory). Full audit trail captured.
-- ════════════════════════════════════════════════════════════════════════════

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
  v_instance    RECORD;
  v_target_step RECORD;
  v_approver_id uuid;
  v_due_at      timestamptz;
  v_new_task_id uuid;
  v_task        RECORD;
BEGIN
  -- ── Access check ───────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_force_advance: insufficient permissions';
  END IF;

  -- ── Reason is mandatory ────────────────────────────────────────────────────
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_force_advance: reason is required';
  END IF;

  -- ── Load and lock instance ─────────────────────────────────────────────────
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

  -- ── Validate target step ───────────────────────────────────────────────────
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

  -- ── Mark all pending tasks before target as force_advanced ─────────────────
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

    -- Notify the bypassed approver that their task was removed
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

  -- ── Resolve approver for target step ──────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_target_step.id, p_instance_id);

  -- ── Compute SLA deadline ──────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_target_step.sla_hours IS NOT NULL
    THEN now() + (v_target_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create task for target step ────────────────────────────────────────────
  IF v_approver_id IS NOT NULL THEN
    INSERT INTO workflow_tasks
      (instance_id, step_id, step_order, assigned_to, due_at)
    VALUES
      (p_instance_id, v_target_step.id, v_target_step.step_order,
       v_approver_id, v_due_at)
    RETURNING id INTO v_new_task_id;
  END IF;

  -- ── Advance instance ───────────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    current_step = p_target_step_order,
         status       = 'in_progress',
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    p_instance_id,
    v_new_task_id,          -- task just created (NULL if no approver found)
    auth.uid(),
    'force_advanced',
    p_target_step_order,
    p_reason,
    jsonb_build_object(
      'from_step',   v_instance.current_step,
      'to_step',     p_target_step_order,
      'reason',      p_reason,
      'new_task_id', v_new_task_id
    )
  );

  -- ── Notify submitter ───────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.force_advanced',
    v_instance.submitted_by,
    jsonb_build_object(
      'step_name', v_target_step.name,
      'reason',    p_reason
    )
  );

  -- ── Notify new assignee ────────────────────────────────────────────────────
  IF v_approver_id IS NOT NULL THEN
    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.task_assigned',
      v_approver_id,
      jsonb_build_object(
        'step_name',   v_target_step.name,
        'module_code', v_instance.module_code
      )
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_force_advance(uuid, integer, text) IS
  'Admin-only: skip the current pending step(s) and advance the instance to a '
  'chosen future step. Bypassed tasks are marked force_advanced. '
  'Reason is mandatory. Full audit trail written.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. wf_admin_decline()
--
-- Admin returns the request to the submitter for review (like wf_return_to_initiator
-- but triggered by admin rather than an approver). Instance moves to
-- awaiting_clarification. Submitter decides to resubmit or withdraw.
-- Reason is mandatory.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_admin_decline(
  p_instance_id uuid,
  p_reason      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  -- ── Access check ───────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RAISE EXCEPTION 'wf_admin_decline: insufficient permissions';
  END IF;

  -- ── Reason is mandatory ────────────────────────────────────────────────────
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_admin_decline: reason is required';
  END IF;

  -- ── Load and lock instance ─────────────────────────────────────────────────
  SELECT id, submitted_by, module_code, record_id, status, current_step
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_admin_decline: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status NOT IN ('in_progress', 'awaiting_clarification') THEN
    RAISE EXCEPTION 'wf_admin_decline: instance is not active (status: %)',
                    v_instance.status;
  END IF;

  -- ── Cancel all pending tasks ───────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'cancelled',
         notes    = p_reason,
         acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- ── Pause instance — return to submitter ──────────────────────────────────
  UPDATE workflow_instances
  SET    status     = 'awaiting_clarification',
         updated_at = now()
  WHERE  id = p_instance_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, step_order, notes, metadata)
  VALUES (
    p_instance_id,
    auth.uid(),
    'admin_declined',
    v_instance.current_step,
    p_reason,
    jsonb_build_object('reason', p_reason)
  );

  -- ── Notify submitter ───────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.admin_declined',
    v_instance.submitted_by,
    jsonb_build_object('reason', p_reason)
  );
END;
$$;

COMMENT ON FUNCTION wf_admin_decline(uuid, text) IS
  'Admin-only: decline / return a workflow instance to the submitter. '
  'All pending tasks are cancelled; instance moves to awaiting_clarification. '
  'Submitter can resubmit or withdraw. Reason is mandatory.';


-- ════════════════════════════════════════════════════════════════════════════
-- 5. Update wf_reassign() to also notify the OLD assignee
--    (previously only the new assignee was notified)
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
  v_task     RECORD;
  v_new_task uuid;
BEGIN
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

  IF NOT has_role('admin') AND v_task.assigned_to != auth.uid() THEN
    RAISE EXCEPTION 'wf_reassign: you cannot reassign this task';
  END IF;

  -- ── Mark old task reassigned ──────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'reassigned',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- ── Create new task for the new assignee ──────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_task.instance_id, v_task.step_id, v_task.step_order,
     p_new_profile_id, v_task.due_at)
  RETURNING id INTO v_new_task;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes, metadata)
  VALUES
    (v_task.instance_id, v_new_task, auth.uid(), 'reassigned',
     v_task.step_order, p_reason,
     jsonb_build_object(
       'from_profile', v_task.assigned_to,
       'to_profile',   p_new_profile_id
     ));

  -- ── Notify old assignee — task removed from their queue ───────────────────
  IF v_task.assigned_to != auth.uid() THEN
    PERFORM wf_queue_notification(
      v_task.instance_id,
      'wf.task_removed',
      v_task.assigned_to,
      jsonb_build_object(
        'step_order', v_task.step_order,
        'reason',     COALESCE(p_reason, 'Task reassigned by admin')
      )
    );
  END IF;

  -- ── Notify new assignee ───────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.reassigned',
    p_new_profile_id,
    jsonb_build_object('step_order', v_task.step_order)
  );
END;
$$;

COMMENT ON FUNCTION wf_reassign(uuid, uuid, text) IS
  'Reassigns a pending task to a new approver. The old task is marked '
  'reassigned (preserved for audit); a new task is created for the new assignee. '
  'Both old and new assignees receive notifications.';


-- ════════════════════════════════════════════════════════════════════════════
-- 6. Notification templates
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  ('wf.task_removed',
   'Your approval task has been reassigned',
   'An admin has reassigned or advanced past your approval task. No further action is required from you.'),

  ('wf.force_advanced',
   'Your request has been advanced to: {{step_name}}',
   'An admin has moved your request forward to the "{{step_name}}" stage. Reason: {{reason}}'),

  ('wf.admin_declined',
   'Admin has returned your request for review',
   'An admin has returned your request. Reason: {{reason}}. Please review the feedback in My Requests and resubmit or withdraw.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ════════════════════════════════════════════════════════════════════════════
-- 7. Verification
-- ════════════════════════════════════════════════════════════════════════════

-- View columns
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name   = 'vw_wf_operations'
ORDER  BY ordinal_position;

-- New RPCs
SELECT proname
FROM   pg_proc
WHERE  proname IN ('wf_force_advance', 'wf_admin_decline')
ORDER  BY proname;

-- New notification templates
SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code IN ('wf.task_removed', 'wf.force_advanced', 'wf.admin_declined')
ORDER  BY code;
