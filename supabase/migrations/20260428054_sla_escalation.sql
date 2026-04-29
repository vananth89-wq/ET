-- =============================================================================
-- Migration 054: SLA Escalation
--
-- When a workflow task's due_at passes and it is still pending, this module:
--   1. Sends a reminder notification to the assigned approver
--   2. Sends an escalation notification to the approver's line manager
--   3. Marks the task as escalated (escalated_at) so we don't repeat it
--
-- A pg_cron job runs wf_escalate_overdue_tasks() every 30 minutes.
--
-- New objects:
--   workflow_tasks.escalated_at         — timestamp when escalation was sent
--   wf.sla_reminder                     — notification template for approver
--   wf.sla_escalation                   — notification template for manager
--   wf_escalate_overdue_tasks()         — RPC that finds & escalates overdue tasks
--   pg_cron: escalate-overdue-tasks     — schedule every 30 min
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. Add escalated_at to workflow_tasks
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_tasks
  ADD COLUMN IF NOT EXISTS escalated_at timestamptz DEFAULT NULL;

COMMENT ON COLUMN workflow_tasks.escalated_at IS
  'Timestamp when SLA escalation notifications were sent for this task. '
  'NULL = not yet escalated. Set by wf_escalate_overdue_tasks().';

CREATE INDEX IF NOT EXISTS wf_tasks_escalation_idx
  ON workflow_tasks (status, due_at, escalated_at)
  WHERE status = 'pending' AND due_at IS NOT NULL AND escalated_at IS NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. Seed notification templates
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  (
    'wf.sla_reminder',
    'Action required: "{{step_name}}" is overdue',
    'Your approval task for "{{record_label}}" (step: {{step_name}}) has passed its SLA deadline and is waiting for your action. Please review it in your Workflow Inbox.'
  ),
  (
    'wf.sla_escalation',
    'Escalation: overdue approval task for {{approver_name}}',
    'A workflow approval task assigned to {{approver_name}} (step: {{step_name}}, request: "{{record_label}}") has passed its SLA deadline and has not been acted upon. Please follow up or reassign.'
  )
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();

COMMENT ON TABLE workflow_notification_templates IS
  'Message templates for workflow notifications. Placeholders in {{braces}} are '
  'substituted from workflow_notification_queue.payload at delivery time.';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. wf_escalate_overdue_tasks
--    Finds all pending tasks whose due_at has passed and escalated_at is NULL.
--    For each:
--      a. Queues a reminder to the assigned approver (wf.sla_reminder)
--      b. Looks up the approver's manager via employees.manager_id
--      c. If a manager profile exists, queues an escalation (wf.sla_escalation)
--      d. Sets escalated_at = now() on the task
--    Returns the count of tasks escalated.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wf_escalate_overdue_tasks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row            RECORD;
  v_manager_profile uuid;
  v_approver_name  text;
  v_step_name      text;
  v_record_label   text;
  v_count          integer := 0;
BEGIN
  FOR v_row IN
    SELECT
      wt.id            AS task_id,
      wt.instance_id,
      wt.assigned_to   AS approver_profile_id,
      wt.step_id,
      ws.name          AS step_name,
      ws.sla_hours,
      wi.module_code,
      wi.record_id
    FROM   workflow_tasks     wt
    JOIN   workflow_instances wi ON wi.id = wt.instance_id
    JOIN   workflow_steps     ws ON ws.id = wt.step_id
    WHERE  wt.status        = 'pending'
      AND  wt.due_at        IS NOT NULL
      AND  wt.due_at        < now()
      AND  wt.escalated_at  IS NULL
    ORDER  BY wt.due_at
    FOR UPDATE OF wt SKIP LOCKED
  LOOP
    -- ── a. Resolve human-readable identifiers ───────────────────────────────

    -- Approver name from employees table (bridge through profiles.employee_id)
    SELECT emp.name INTO v_approver_name
    FROM   employees emp
    JOIN   profiles  p ON p.employee_id = emp.id
    WHERE  p.id = v_row.approver_profile_id
    LIMIT  1;

    v_approver_name  := COALESCE(v_approver_name, 'Unknown');
    v_step_name      := v_row.step_name;
    -- Use module_code + short record_id as label (modules can override later)
    v_record_label   := v_row.module_code || ' #' || substring(v_row.record_id::text, 1, 8);

    -- ── b. Notify the approver (reminder) ──────────────────────────────────
    PERFORM wf_queue_notification(
      v_row.instance_id,
      'wf.sla_reminder',
      v_row.approver_profile_id,
      jsonb_build_object(
        'step_name',    v_step_name,
        'record_label', v_record_label,
        'task_id',      v_row.task_id
      )
    );

    -- ── c. Notify the approver's manager ───────────────────────────────────
    -- Bridge: profile → employee → manager employee → manager profile
    SELECT p_mgr.id INTO v_manager_profile
    FROM   employees approver_emp
    JOIN   profiles  p_approver ON p_approver.employee_id = approver_emp.id
    JOIN   employees mgr_emp    ON mgr_emp.id = approver_emp.manager_id
    JOIN   profiles  p_mgr      ON p_mgr.employee_id = mgr_emp.id
    WHERE  p_approver.id = v_row.approver_profile_id
    LIMIT  1;

    IF v_manager_profile IS NOT NULL THEN
      PERFORM wf_queue_notification(
        v_row.instance_id,
        'wf.sla_escalation',
        v_manager_profile,
        jsonb_build_object(
          'step_name',     v_step_name,
          'approver_name', v_approver_name,
          'record_label',  v_record_label,
          'task_id',       v_row.task_id
        )
      );
    ELSE
      RAISE NOTICE 'wf_escalate_overdue_tasks: no manager found for approver %, skipping escalation for task %',
        v_row.approver_profile_id, v_row.task_id;
    END IF;

    -- ── d. Mark task as escalated ───────────────────────────────────────────
    UPDATE workflow_tasks
    SET    escalated_at = now()
    WHERE  id = v_row.task_id;

    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE 'wf_escalate_overdue_tasks: escalated % task(s)', v_count;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION wf_escalate_overdue_tasks() IS
  'Finds pending tasks past their SLA due_at and sends notifications to the '
  'assigned approver and their line manager. Marks each task with escalated_at '
  'to prevent duplicate escalations. Safe to call multiple times. '
  'Called by pg_cron every 30 minutes.';


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Schedule pg_cron job — every 30 minutes
-- ════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  -- Safely remove existing schedule if it exists
  BEGIN
    PERFORM cron.unschedule('escalate-overdue-tasks');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM cron.schedule(
    'escalate-overdue-tasks',
    '*/30 * * * *',
    $cron$ SELECT wf_escalate_overdue_tasks(); $cron$
  );

  RAISE NOTICE 'pg_cron: escalate-overdue-tasks scheduled every 30 minutes';
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Confirm column added
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'workflow_tasks'
  AND  column_name = 'escalated_at';

-- Confirm templates seeded
SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code IN ('wf.sla_reminder', 'wf.sla_escalation');

-- Confirm function created
SELECT proname FROM pg_proc WHERE proname = 'wf_escalate_overdue_tasks';

-- Confirm cron job scheduled
SELECT jobname, schedule FROM cron.job WHERE jobname = 'escalate-overdue-tasks';
