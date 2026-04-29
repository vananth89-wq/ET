-- =============================================================================
-- Jobs Framework
--
-- Adds a generic background-job infrastructure and the first concrete job:
-- the Workflow SLA Monitor.
--
--   1. job_run_log          — append-only history of every job execution
--   2. wf_process_sla_events() — SLA monitor: reminders + escalations
--   3. pg_cron schedule     — runs SLA monitor every 15 minutes
--   4. Extra notification templates for reminder / escalation
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — job_run_log TABLE
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS job_run_log (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_code        text        NOT NULL,          -- stable identifier, e.g. 'wf_sla_monitor'
  job_name        text        NOT NULL,          -- human label
  triggered_by    uuid        REFERENCES profiles(id),  -- NULL = scheduled, uuid = manual
  started_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  duration_ms     integer     GENERATED ALWAYS AS (
                    CAST(EXTRACT(EPOCH FROM (completed_at - started_at)) * 1000 AS integer)
                  ) STORED,
  status          text        NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running', 'success', 'partial', 'failed')),
  rows_processed  integer,
  summary         jsonb,       -- arbitrary stats, e.g. {"reminders":3,"escalations":1}
  error_message   text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE job_run_log IS
  'Append-only log of every background-job execution. '
  'triggered_by = NULL means the run was initiated by pg_cron; '
  'a profile id means it was manually triggered from the UI.';

CREATE INDEX IF NOT EXISTS job_run_log_code_started_idx
  ON job_run_log (job_code, started_at DESC);

-- RLS: admins can read all runs; regular users see nothing
ALTER TABLE job_run_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS job_run_log_admin ON job_run_log;
CREATE POLICY job_run_log_admin ON job_run_log FOR ALL
  USING (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — EXTRA NOTIFICATION TEMPLATES
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  -- Sent to approver when reminder_after_hours threshold is crossed
  ('wf.sla_reminder',
   'Reminder: approval task awaiting your action',
   'Your approval task "{{step_name}}" has been waiting for {{hours_elapsed}} hours. '
   'Please review and act before the deadline.'),

  -- Sent to the new assignee when a task is escalated
  ('wf.sla_escalated',
   'Task escalated to you: {{step_name}}',
   'An approval task "{{step_name}}" was escalated to you because the previous approver '
   'did not action it within the required time. Please review it promptly.'),

  -- Sent to the original approver to inform them the task was taken away
  ('wf.sla_escalated_notice',
   'Your approval task has been escalated',
   'Your approval task "{{step_name}}" has been escalated to your manager because the '
   'SLA deadline was exceeded. No further action is required from you.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — wf_process_sla_events()
-- ════════════════════════════════════════════════════════════════════════════
--
-- Scans every pending workflow task and:
--
--   REMINDER  — fires when now() ≥ task.created_at + step.reminder_after_hours
--               AND no 'warning' sla_event exists yet for this task.
--               → queues wf.sla_reminder notification to the current assignee
--               → inserts workflow_sla_events(event_type='warning')
--
--   ESCALATION — fires when now() ≥ task.created_at + step.escalation_after_hours
--               AND no 'breach' sla_event exists yet for this task.
--               → finds the assignee's line manager's profile
--               → reassigns the task to the manager
--               → queues wf.sla_escalated  to the manager
--               → queues wf.sla_escalated_notice to the original assignee
--               → inserts workflow_sla_events(event_type='breach')
--
-- Returns a jsonb summary:
--   { "reminders": N, "escalations": N, "skipped": N, "errors": N }
--
-- Safe to run repeatedly — idempotent via sla_events dedup check.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_process_sla_events(
  p_triggered_by uuid DEFAULT NULL   -- pass auth.uid() for manual runs
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id        uuid;
  v_task          RECORD;
  v_manager_pid   uuid;
  v_reminders     integer := 0;
  v_escalations   integer := 0;
  v_skipped       integer := 0;
  v_errors        integer := 0;
  v_summary       jsonb;
BEGIN
  -- ── Open job run log entry ─────────────────────────────────────────────────
  INSERT INTO job_run_log (job_code, job_name, triggered_by, status)
  VALUES ('wf_sla_monitor', 'Workflow SLA Monitor', p_triggered_by, 'running')
  RETURNING id INTO v_log_id;

  -- ── Main loop: one iteration per pending task ──────────────────────────────
  FOR v_task IN
    SELECT
      wt.id                         AS task_id,
      wt.instance_id,
      wt.step_id,
      wt.assigned_to,
      wt.created_at                 AS task_created_at,
      ws.name                       AS step_name,
      ws.reminder_after_hours,
      ws.escalation_after_hours
    FROM  workflow_tasks    wt
    JOIN  workflow_steps    ws  ON ws.id = wt.step_id
    WHERE wt.status = 'pending'
      AND (
        ws.reminder_after_hours   IS NOT NULL
        OR ws.escalation_after_hours IS NOT NULL
      )
    ORDER BY wt.created_at        -- oldest first
    FOR UPDATE OF wt SKIP LOCKED  -- safe for concurrent runs
  LOOP
    BEGIN

      -- ── REMINDER ──────────────────────────────────────────────────────────
      IF  v_task.reminder_after_hours IS NOT NULL
      AND now() >= v_task.task_created_at
                   + (v_task.reminder_after_hours || ' hours')::interval
      AND NOT EXISTS (
            SELECT 1 FROM workflow_sla_events
            WHERE task_id   = v_task.task_id
              AND event_type = 'warning'
          )
      THEN
        -- Log the SLA event so we don't send duplicate reminders
        INSERT INTO workflow_sla_events (task_id, event_type)
        VALUES (v_task.task_id, 'warning');

        -- Queue notification to current assignee
        INSERT INTO workflow_notification_queue
               (instance_id, template_code, target_profile, payload)
        VALUES (
          v_task.instance_id,
          'wf.sla_reminder',
          v_task.assigned_to,
          jsonb_build_object(
            'step_name',     v_task.step_name,
            'hours_elapsed', ROUND(
              EXTRACT(EPOCH FROM (now() - v_task.task_created_at)) / 3600
            )::text
          )
        );

        v_reminders := v_reminders + 1;
      END IF;

      -- ── ESCALATION ────────────────────────────────────────────────────────
      IF  v_task.escalation_after_hours IS NOT NULL
      AND now() >= v_task.task_created_at
                   + (v_task.escalation_after_hours || ' hours')::interval
      AND NOT EXISTS (
            SELECT 1 FROM workflow_sla_events
            WHERE task_id    = v_task.task_id
              AND event_type  = 'breach'
          )
      THEN
        -- Find assignee's line manager's active profile
        SELECT p_mgr.id
        INTO   v_manager_pid
        FROM   profiles   p_cur
        JOIN   employees  e_cur ON e_cur.id = p_cur.employee_id
        JOIN   employees  e_mgr ON e_mgr.id = e_cur.manager_id
        JOIN   profiles   p_mgr ON p_mgr.employee_id = e_mgr.id
                                AND p_mgr.is_active   = true
        WHERE  p_cur.id = v_task.assigned_to
        LIMIT  1;

        IF v_manager_pid IS NOT NULL AND v_manager_pid != v_task.assigned_to THEN
          -- Reassign task to manager
          UPDATE workflow_tasks
          SET    assigned_to = v_manager_pid
          WHERE  id          = v_task.task_id;

          -- Log the breach SLA event
          INSERT INTO workflow_sla_events (task_id, event_type)
          VALUES (v_task.task_id, 'breach');

          -- Notify the manager (new assignee)
          INSERT INTO workflow_notification_queue
                 (instance_id, template_code, target_profile, payload)
          VALUES (
            v_task.instance_id,
            'wf.sla_escalated',
            v_manager_pid,
            jsonb_build_object('step_name', v_task.step_name)
          );

          -- Notify the original approver that it was taken away
          INSERT INTO workflow_notification_queue
                 (instance_id, template_code, target_profile, payload)
          VALUES (
            v_task.instance_id,
            'wf.sla_escalated_notice',
            v_task.assigned_to,
            jsonb_build_object('step_name', v_task.step_name)
          );

          v_escalations := v_escalations + 1;

        ELSE
          -- No manager found or manager is same person — skip escalation
          v_skipped := v_skipped + 1;
        END IF;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Never let one bad row abort the whole run
      v_errors := v_errors + 1;
    END;
  END LOOP;

  -- ── Close job run log entry ────────────────────────────────────────────────
  v_summary := jsonb_build_object(
    'reminders',   v_reminders,
    'escalations', v_escalations,
    'skipped',     v_skipped,
    'errors',      v_errors
  );

  UPDATE job_run_log
  SET    status         = CASE
                            WHEN v_errors > 0 AND (v_reminders + v_escalations) = 0
                              THEN 'failed'
                            WHEN v_errors > 0
                              THEN 'partial'
                            ELSE 'success'
                          END,
         completed_at   = now(),
         rows_processed = v_reminders + v_escalations,
         summary        = v_summary
  WHERE  id = v_log_id;

  RETURN v_summary;

EXCEPTION WHEN OTHERS THEN
  -- Catch-all: mark job as failed so the log row isn't stuck in 'running'
  UPDATE job_run_log
  SET    status        = 'failed',
         completed_at  = now(),
         error_message = SQLERRM
  WHERE  id = v_log_id;
  RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION wf_process_sla_events(uuid) IS
  'SLA monitor job. Sends reminder notifications and escalates overdue tasks '
  'to the assignee''s line manager. Idempotent — uses workflow_sla_events to '
  'prevent duplicate actions. Pass auth.uid() for manual runs.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — pg_cron SCHEDULE
-- ════════════════════════════════════════════════════════════════════════════
--
-- Runs the SLA monitor every 15 minutes.
-- pg_cron must be enabled in Supabase: Dashboard → Database → Extensions → pg_cron
--
-- If pg_cron is not yet enabled this block will fail gracefully via the DO
-- block's exception handler — the function and table are still created above.

DO $$
BEGIN
  -- Remove any stale schedule with the same name first
  PERFORM cron.unschedule('wf-sla-monitor')
  WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'wf-sla-monitor'
  );

  PERFORM cron.schedule(
    'wf-sla-monitor',                              -- job name
    '*/15 * * * *',                                -- every 15 minutes
    'SELECT wf_process_sla_events(NULL)'           -- NULL = scheduled (not manual)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available — schedule skipped: %', SQLERRM;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 5 — VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'job_run_log'
ORDER  BY ordinal_position;

SELECT code, title_tmpl
FROM   workflow_notification_templates
WHERE  code LIKE 'wf.sla%'
ORDER  BY code;

SELECT proname
FROM   pg_proc
WHERE  proname = 'wf_process_sla_events';
