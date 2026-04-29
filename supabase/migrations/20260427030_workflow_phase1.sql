-- =============================================================================
-- Phase 1: Generic Workflow Engine
--
-- A module-agnostic approval workflow engine that can drive any approval
-- process in the application (expense reports, leave requests, purchase orders,
-- etc.) via a template + step configuration.
--
-- Structure:
--   Part  1 — Core tables (templates, steps, conditions, instances, tasks,
--             action_log, delegations, sla_events)
--   Part  2 — Notification tables (notification_templates, notification_queue)
--   Part  3 — Indexes
--   Part  4 — Row Level Security
--   Part  5 — Helper functions
--             · wf_resolve_approver()     — single entry point for all approver resolution
--             · wf_evaluate_skip_step()   — condition evaluator (skip-step logic)
--             · wf_queue_notification()   — queue a templated notification
--             · wf_sync_module_status()   — update module record status after workflow event
--   Part  6 — Core RPCs
--             · wf_submit()              — start a new workflow instance
--             · wf_advance_instance()    — internal: advance to next step or complete
--             · wf_approve()             — approve an assigned task
--             · wf_reject()              — reject at any approval step
--             · wf_reassign()            — delegate a task to another approver
--             · wf_withdraw()            — submitter withdraws an in-flight request
--   Part  7 — Reporting views
--             · vw_wf_pending_tasks      — tasks the current user needs to act on
--             · vw_wf_my_requests        — instances submitted by the current user
--   Part  8 — Permissions seed
--   Part  9 — Seed data
--             · EXPENSE_APPROVAL template (2 steps: Manager → Finance)
--             · Notification message templates
--   Part 10 — Verification queries
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — CORE TABLES
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1a. workflow_templates ────────────────────────────────────────────────────
-- One row per named workflow process (EXPENSE_APPROVAL, LEAVE_REQUEST, etc.)
-- version is bumped when the template's steps change; running instances record
-- the version they were created against so they are not broken by later edits.

CREATE TABLE IF NOT EXISTS workflow_templates (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text        NOT NULL UNIQUE,           -- e.g. 'EXPENSE_APPROVAL'
  name         text        NOT NULL,
  description  text,
  module_code  text        NOT NULL,                  -- maps to DB table name
  is_active    boolean     NOT NULL DEFAULT true,
  version      integer     NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow_templates IS
  'Named workflow process definitions. Each template defines which module it '
  'applies to and contains one or more ordered steps.';

COMMENT ON COLUMN workflow_templates.module_code IS
  'Snake-case identifier matching the DB table (e.g. expense_reports, leave_requests). '
  'Used by wf_sync_module_status() to update the source record.';


-- ── 1b. workflow_steps ────────────────────────────────────────────────────────
-- Ordered steps within a template. Each step names who approves and how long
-- they have (SLA hours). The step_order column drives sequencing.

CREATE TABLE IF NOT EXISTS workflow_steps (
  id               uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id      uuid    NOT NULL REFERENCES workflow_templates(id) ON DELETE CASCADE,
  step_order       integer NOT NULL,                  -- 1-based; must be unique per template
  name             text    NOT NULL,
  approver_type    text    NOT NULL
                   CHECK (approver_type IN (
                     'MANAGER',        -- submitter's line manager
                     'ROLE',           -- any user with approver_role
                     'DEPT_HEAD',      -- submitter's department head
                     'SPECIFIC_USER',  -- fixed profile (approver_profile_id)
                     'RULE_BASED'      -- evaluate workflow_step_conditions
                   )),
  approver_role    text,               -- role.code when approver_type = 'ROLE'
  approver_profile_id uuid REFERENCES profiles(id),  -- when approver_type = 'SPECIFIC_USER'
  sla_hours        integer,            -- NULL = no SLA deadline
  allow_delegation boolean NOT NULL DEFAULT true,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (template_id, step_order)
);

COMMENT ON TABLE workflow_steps IS
  'Ordered approval steps within a workflow template.';

COMMENT ON COLUMN workflow_steps.approver_type IS
  'MANAGER=submitter''s direct manager, ROLE=any user with approver_role, '
  'DEPT_HEAD=submitter''s department head, SPECIFIC_USER=fixed profile, '
  'RULE_BASED=evaluate step conditions against instance metadata.';


-- ── 1c. workflow_step_conditions ─────────────────────────────────────────────
-- Optional conditions attached to a step.  When skip_step=true and the
-- condition evaluates true against the instance metadata snapshot, the step
-- is skipped entirely.  Multiple rows are ANDed together.

CREATE TABLE IF NOT EXISTS workflow_step_conditions (
  id          uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  step_id     uuid  NOT NULL REFERENCES workflow_steps(id) ON DELETE CASCADE,
  field_path  text  NOT NULL,       -- key path in instance.metadata jsonb
  operator    text  NOT NULL
              CHECK (operator IN ('gt','gte','lt','lte','eq','neq','in','not_in')),
  value       text  NOT NULL,       -- comparison value (numeric comparisons cast at runtime)
  skip_step   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow_step_conditions IS
  'Conditional routing rules evaluated against the instance metadata snapshot. '
  'When skip_step=true and all conditions on the step evaluate to true, the step '
  'is bypassed automatically.';


-- ── 1d. workflow_instances ────────────────────────────────────────────────────
-- One row per in-flight (or completed) workflow run tied to a module record.
-- metadata is a JSON snapshot of the source record at submission time, used
-- for condition evaluation even if the source record changes later.
--
-- The initial schema (20260419001) has a placeholder workflow_instances table
-- with different columns (entity_type / entity_id). Drop it first so we can
-- create the real schema. CASCADE also drops any stale RLS policies on it.

DROP TABLE IF EXISTS workflow_instances CASCADE;

CREATE TABLE workflow_instances (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id      uuid        NOT NULL REFERENCES workflow_templates(id),
  template_version integer     NOT NULL DEFAULT 1,
  module_code      text        NOT NULL,
  record_id        uuid        NOT NULL,
  submitted_by     uuid        NOT NULL REFERENCES profiles(id),
  current_step     integer     NOT NULL DEFAULT 1,
  status           text        NOT NULL DEFAULT 'in_progress'
                   CHECK (status IN (
                     'in_progress',   -- awaiting approval action
                     'approved',      -- all steps completed
                     'rejected',      -- rejected at any step
                     'withdrawn',     -- submitter withdrew
                     'cancelled'      -- admin-cancelled
                   )),
  metadata         jsonb       NOT NULL DEFAULT '{}',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz
);

COMMENT ON TABLE workflow_instances IS
  'Running or completed workflow instances. One instance per workflow run of a '
  'module record. metadata is a point-in-time snapshot of the record used for '
  'dynamic routing decisions.';

-- Only one active workflow per module record at a time
CREATE UNIQUE INDEX IF NOT EXISTS workflow_instances_active_record_idx
  ON workflow_instances (module_code, record_id)
  WHERE status = 'in_progress';


-- ── 1e. workflow_tasks ────────────────────────────────────────────────────────
-- Individual approval task assigned to a specific user for a specific step.
-- Reassigning creates a new task row (old one marked 'reassigned') to preserve
-- the full audit trail.

CREATE TABLE IF NOT EXISTS workflow_tasks (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id  uuid        NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  step_id      uuid        NOT NULL REFERENCES workflow_steps(id),
  step_order   integer     NOT NULL,
  assigned_to  uuid        NOT NULL REFERENCES profiles(id),
  status       text        NOT NULL DEFAULT 'pending'
               CHECK (status IN (
                 'pending',     -- awaiting action
                 'approved',    -- approved by assignee
                 'rejected',    -- rejected by assignee
                 'reassigned',  -- delegated to someone else
                 'skipped',     -- step auto-skipped by condition
                 'cancelled'    -- workflow was withdrawn/cancelled
               )),
  notes        text,
  acted_at     timestamptz,
  due_at       timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow_tasks IS
  'Approval tasks assigned to individual users. Each row is immutable once '
  'acted upon; reassigning creates a new row so the full trail is preserved.';


-- ── 1f. workflow_action_log ───────────────────────────────────────────────────
-- Append-only event log. Every state change (submit, approve, reject, withdraw,
-- reassign, complete, cancel) writes a row here. Never update or delete.

CREATE TABLE IF NOT EXISTS workflow_action_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id  uuid        NOT NULL REFERENCES workflow_instances(id),
  task_id      uuid        REFERENCES workflow_tasks(id),
  actor_id     uuid        NOT NULL REFERENCES profiles(id),
  action       text        NOT NULL,  -- submitted|approved|rejected|reassigned|withdrawn|completed|cancelled
  step_order   integer,
  notes        text,
  metadata     jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow_action_log IS
  'Immutable, append-only audit trail for every workflow state change. '
  'Never update or delete rows here.';


-- ── 1g. workflow_delegations ─────────────────────────────────────────────────
-- Temporary delegation of approval authority. When a task is created for a
-- delegator who has an active delegation, the task is auto-assigned to the
-- delegate instead.

CREATE TABLE IF NOT EXISTS workflow_delegations (
  id            uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  delegator_id  uuid    NOT NULL REFERENCES profiles(id),
  delegate_id   uuid    NOT NULL REFERENCES profiles(id),
  template_id   uuid    REFERENCES workflow_templates(id),   -- NULL = all templates
  from_date     date    NOT NULL,
  to_date       date    NOT NULL,
  reason        text,
  is_active     boolean NOT NULL DEFAULT true,
  created_by    uuid    REFERENCES profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (from_date <= to_date),
  CHECK (delegator_id != delegate_id)
);

COMMENT ON TABLE workflow_delegations IS
  'Temporary delegation of approval authority (e.g. during leave). When a task '
  'is routed to a delegator who has an active delegation for the template, the '
  'task is assigned to the delegate instead.';


-- ── 1h. workflow_sla_events ───────────────────────────────────────────────────
-- Fired when a task approaches or breaches its due date.

CREATE TABLE IF NOT EXISTS workflow_sla_events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id     uuid        NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  event_type  text        NOT NULL CHECK (event_type IN ('warning', 'breach')),
  fired_at    timestamptz NOT NULL DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — NOTIFICATION TABLES
-- ════════════════════════════════════════════════════════════════════════════

-- ── 2a. workflow_notification_templates ──────────────────────────────────────
-- Mustache-style templates. Placeholders like {{submitter_name}} are resolved
-- at queue-processing time from the notification_queue.payload jsonb.

CREATE TABLE IF NOT EXISTS workflow_notification_templates (
  id          uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text  NOT NULL UNIQUE,    -- e.g. 'wf.task_assigned'
  title_tmpl  text  NOT NULL,
  body_tmpl   text  NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflow_notification_templates IS
  'Message templates for workflow notifications. Placeholders in {{braces}} are '
  'substituted from workflow_notification_queue.payload at delivery time.';


-- ── 2b. workflow_notification_queue ──────────────────────────────────────────
-- Staging table for outbound notifications. A background job (pg_cron or
-- Supabase Edge Function) reads pending rows, renders the template, writes to
-- the existing notifications table, then marks the row as sent.

CREATE TABLE IF NOT EXISTS workflow_notification_queue (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id     uuid        NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  template_code   text        NOT NULL,
  target_profile  uuid        NOT NULL REFERENCES profiles(id),
  payload         jsonb       NOT NULL DEFAULT '{}',
  status          text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'sent', 'failed')),
  error_message   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz
);

COMMENT ON TABLE workflow_notification_queue IS
  'Outbound notification queue for workflow events. A background processor '
  'renders the template_code message using payload and delivers to the '
  'notifications table, then marks this row as sent.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — INDEXES
-- ════════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS wf_instances_module_record_idx
  ON workflow_instances (module_code, record_id);

CREATE INDEX IF NOT EXISTS wf_instances_submitted_by_idx
  ON workflow_instances (submitted_by);

CREATE INDEX IF NOT EXISTS wf_instances_status_idx
  ON workflow_instances (status)
  WHERE status = 'in_progress';

CREATE INDEX IF NOT EXISTS wf_tasks_assigned_pending_idx
  ON workflow_tasks (assigned_to, status)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS wf_tasks_instance_idx
  ON workflow_tasks (instance_id, step_order);

CREATE INDEX IF NOT EXISTS wf_action_log_instance_idx
  ON workflow_action_log (instance_id, created_at DESC);

CREATE INDEX IF NOT EXISTS wf_delegations_delegator_active_idx
  ON workflow_delegations (delegator_id, from_date, to_date)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS wf_notif_queue_pending_idx
  ON workflow_notification_queue (status, created_at)
  WHERE status = 'pending';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE workflow_templates            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_steps                ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_step_conditions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_instances            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_tasks                ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_action_log           ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_delegations          ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_sla_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_notification_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_notification_queue   ENABLE ROW LEVEL SECURITY;


-- ── Templates & Steps — readable by all authenticated users ──────────────────

DROP POLICY IF EXISTS wf_templates_select          ON workflow_templates;
DROP POLICY IF EXISTS wf_templates_admin_all       ON workflow_templates;
DROP POLICY IF EXISTS wf_steps_select              ON workflow_steps;
DROP POLICY IF EXISTS wf_steps_admin_all           ON workflow_steps;
DROP POLICY IF EXISTS wf_conditions_select         ON workflow_step_conditions;
DROP POLICY IF EXISTS wf_conditions_admin_all      ON workflow_step_conditions;

CREATE POLICY wf_templates_select ON workflow_templates FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY wf_templates_admin_all ON workflow_templates FOR ALL
  USING (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY wf_steps_select ON workflow_steps FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY wf_steps_admin_all ON workflow_steps FOR ALL
  USING (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY wf_conditions_select ON workflow_step_conditions FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY wf_conditions_admin_all ON workflow_step_conditions FOR ALL
  USING (has_role('admin'))
  WITH CHECK (has_role('admin'));


-- ── Instances — submitter sees own; approvers see in-progress; admin sees all ─

DROP POLICY IF EXISTS wf_instances_select ON workflow_instances;
DROP POLICY IF EXISTS wf_instances_admin  ON workflow_instances;

CREATE POLICY wf_instances_select ON workflow_instances FOR SELECT
  USING (
    has_role('admin')
    OR has_permission('workflow.admin')
    OR submitted_by = auth.uid()
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.instance_id = workflow_instances.id
        AND wt.assigned_to = auth.uid()
    )
  );

CREATE POLICY wf_instances_admin ON workflow_instances FOR ALL
  USING (has_role('admin') OR has_permission('workflow.admin'))
  WITH CHECK (has_role('admin') OR has_permission('workflow.admin'));


-- ── Tasks — assignee sees own; admin sees all ─────────────────────────────────

DROP POLICY IF EXISTS wf_tasks_select ON workflow_tasks;
DROP POLICY IF EXISTS wf_tasks_admin  ON workflow_tasks;

CREATE POLICY wf_tasks_select ON workflow_tasks FOR SELECT
  USING (
    has_role('admin')
    OR has_permission('workflow.admin')
    OR assigned_to = auth.uid()
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.id = workflow_tasks.instance_id
        AND wi.submitted_by = auth.uid()
    )
  );

CREATE POLICY wf_tasks_admin ON workflow_tasks FOR ALL
  USING (has_role('admin') OR has_permission('workflow.admin'))
  WITH CHECK (has_role('admin') OR has_permission('workflow.admin'));


-- ── Action log — same visibility as instances ─────────────────────────────────

DROP POLICY IF EXISTS wf_action_log_select ON workflow_action_log;

CREATE POLICY wf_action_log_select ON workflow_action_log FOR SELECT
  USING (
    has_role('admin')
    OR has_permission('workflow.admin')
    OR actor_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.id = workflow_action_log.instance_id
        AND (wi.submitted_by = auth.uid()
          OR EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE wt.instance_id = wi.id AND wt.assigned_to = auth.uid()
          ))
    )
  );


-- ── Delegations — own delegations + admin ────────────────────────────────────

DROP POLICY IF EXISTS wf_delegations_select ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_own    ON workflow_delegations;
DROP POLICY IF EXISTS wf_delegations_admin  ON workflow_delegations;

CREATE POLICY wf_delegations_select ON workflow_delegations FOR SELECT
  USING (
    has_role('admin')
    OR delegator_id = auth.uid()
    OR delegate_id  = auth.uid()
  );

CREATE POLICY wf_delegations_own ON workflow_delegations FOR INSERT
  WITH CHECK (delegator_id = auth.uid() OR has_role('admin'));

CREATE POLICY wf_delegations_admin ON workflow_delegations FOR ALL
  USING (has_role('admin'))
  WITH CHECK (has_role('admin'));


-- ── SLA events — visible to assigned user + admin ────────────────────────────

DROP POLICY IF EXISTS wf_sla_select ON workflow_sla_events;

CREATE POLICY wf_sla_select ON workflow_sla_events FOR SELECT
  USING (
    has_role('admin')
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt
      WHERE wt.id = workflow_sla_events.task_id
        AND wt.assigned_to = auth.uid()
    )
  );


-- ── Notification tables — admin only ─────────────────────────────────────────

DROP POLICY IF EXISTS wf_notif_tmpl_select ON workflow_notification_templates;
DROP POLICY IF EXISTS wf_notif_tmpl_admin  ON workflow_notification_templates;
DROP POLICY IF EXISTS wf_notif_queue_admin ON workflow_notification_queue;

CREATE POLICY wf_notif_tmpl_select ON workflow_notification_templates FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY wf_notif_tmpl_admin ON workflow_notification_templates FOR ALL
  USING (has_role('admin'))
  WITH CHECK (has_role('admin'));

CREATE POLICY wf_notif_queue_admin ON workflow_notification_queue FOR ALL
  USING (has_role('admin') OR has_permission('workflow.admin'))
  WITH CHECK (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- PART 5 — HELPER FUNCTIONS
-- ════════════════════════════════════════════════════════════════════════════

-- ── 5a. wf_evaluate_skip_step() ──────────────────────────────────────────────
-- Returns true if ALL skip_step conditions on a step evaluate to true against
-- the provided metadata snapshot. If there are no skip_step conditions, returns
-- false (step is not skipped).

CREATE OR REPLACE FUNCTION wf_evaluate_skip_step(
  p_step_id  uuid,
  p_metadata jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_condition  RECORD;
  v_field_val  text;
  v_matches    boolean;
  v_all_match  boolean := true;
  v_has_cond   boolean := false;
BEGIN
  FOR v_condition IN
    SELECT field_path, operator, value
    FROM   workflow_step_conditions
    WHERE  step_id    = p_step_id
      AND  skip_step  = true
  LOOP
    v_has_cond  := true;
    v_field_val := p_metadata ->> v_condition.field_path;

    v_matches := CASE v_condition.operator
      WHEN 'eq'     THEN v_field_val = v_condition.value
      WHEN 'neq'    THEN v_field_val != v_condition.value OR v_field_val IS NULL
      WHEN 'gt'     THEN (v_field_val::numeric > v_condition.value::numeric)
      WHEN 'gte'    THEN (v_field_val::numeric >= v_condition.value::numeric)
      WHEN 'lt'     THEN (v_field_val::numeric < v_condition.value::numeric)
      WHEN 'lte'    THEN (v_field_val::numeric <= v_condition.value::numeric)
      WHEN 'in'     THEN v_field_val = ANY(
                           SELECT jsonb_array_elements_text(v_condition.value::jsonb))
      WHEN 'not_in' THEN v_field_val != ALL(
                           SELECT jsonb_array_elements_text(v_condition.value::jsonb))
      ELSE false
    END;

    IF NOT COALESCE(v_matches, false) THEN
      RETURN false;   -- one condition failed → don't skip
    END IF;
  END LOOP;

  RETURN v_has_cond AND v_all_match;
END;
$$;

COMMENT ON FUNCTION wf_evaluate_skip_step(uuid, jsonb) IS
  'Returns true if every skip_step condition on the step evaluates true '
  'against the provided metadata. Returns false if there are no conditions.';


-- ── 5b. wf_resolve_approver() ────────────────────────────────────────────────
-- The single entry point for resolving who approves a given step for a given
-- instance. Returns a profile_id, or NULL if no approver can be found.
-- Delegation is applied here: if the resolved approver has an active
-- delegation that covers today, the delegate's profile_id is returned instead.

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
  v_step            RECORD;
  v_instance        RECORD;
  v_submitter_emp   RECORD;
  v_approver        uuid;
  v_delegate        uuid;
BEGIN
  SELECT approver_type, approver_role, approver_profile_id, template_id
  INTO   v_step
  FROM   workflow_steps
  WHERE  id = p_step_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: step % not found', p_step_id;
  END IF;

  SELECT submitted_by, metadata, module_code
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_resolve_approver: instance % not found', p_instance_id;
  END IF;

  -- Submitter's employee record (needed for MANAGER and DEPT_HEAD resolution)
  SELECT e.id, e.manager_id, e.dept_id
  INTO   v_submitter_emp
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_instance.submitted_by;

  -- ── Resolve by type ──────────────────────────────────────────────────────

  CASE v_step.approver_type

    WHEN 'MANAGER' THEN
      -- Submitter's direct line manager
      SELECT p.id INTO v_approver
      FROM   profiles p
      WHERE  p.employee_id = v_submitter_emp.manager_id
        AND  p.is_active   = true
      LIMIT  1;

    WHEN 'ROLE' THEN
      -- Any active user holding the specified role
      -- (in practice the engine creates one task; parallel-approver logic is
      --  a future enhancement — for now picks the first matching user)
      SELECT ur.profile_id INTO v_approver
      FROM   user_roles ur
      JOIN   roles r ON r.id = ur.role_id AND r.code = v_step.approver_role
      WHERE  ur.is_active   = true
        AND  ur.profile_id != v_instance.submitted_by  -- don't self-approve
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

    WHEN 'RULE_BASED' THEN
      -- Fallback: evaluate step conditions to decide between MANAGER and ROLE.
      -- Phase 1 implementation: any skip_step=false condition with approver_role
      -- in the condition.value selects the role approver; otherwise falls back
      -- to MANAGER. Extend this branch for richer routing in future phases.
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
        -- Fall through to MANAGER
        SELECT p.id INTO v_approver
        FROM   profiles p
        WHERE  p.employee_id = v_submitter_emp.manager_id
          AND  p.is_active   = true
        LIMIT  1;
      END IF;

    ELSE
      v_approver := NULL;
  END CASE;

  -- ── Apply delegation ──────────────────────────────────────────────────────
  -- If the resolved approver has an active delegation covering today, route to
  -- the delegate instead. Only apply when delegation covers this template or
  -- all templates (template_id IS NULL).

  IF v_approver IS NOT NULL THEN
    SELECT delegate_id INTO v_delegate
    FROM   workflow_delegations
    WHERE  delegator_id  = v_approver
      AND  is_active     = true
      AND  CURRENT_DATE BETWEEN from_date AND to_date
      AND  (template_id IS NULL OR template_id = v_step.template_id)
    LIMIT  1;

    IF v_delegate IS NOT NULL THEN
      v_approver := v_delegate;
    END IF;
  END IF;

  RETURN v_approver;
END;
$$;

COMMENT ON FUNCTION wf_resolve_approver(uuid, uuid) IS
  'Resolves the profile_id of the approver for a step in a given instance. '
  'Applies active delegation rules. Returns NULL if no approver is found.';


-- ── 5c. wf_queue_notification() ──────────────────────────────────────────────
-- Writes a row to workflow_notification_queue. A background processor
-- (pg_cron or Edge Function) renders the template and delivers it to the
-- notifications table.

CREATE OR REPLACE FUNCTION wf_queue_notification(
  p_instance_id   uuid,
  p_template_code text,
  p_target_profile uuid,
  p_payload        jsonb DEFAULT '{}'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Silently skip if the notification template doesn't exist (non-fatal)
  IF NOT EXISTS (
    SELECT 1 FROM workflow_notification_templates WHERE code = p_template_code
  ) THEN
    RAISE NOTICE 'wf_queue_notification: template % not found — skipping', p_template_code;
    RETURN;
  END IF;

  INSERT INTO workflow_notification_queue
    (instance_id, template_code, target_profile, payload)
  VALUES
    (p_instance_id, p_template_code, p_target_profile, p_payload);
END;
$$;


-- ── 5d. wf_sync_module_status() ──────────────────────────────────────────────
-- Called after every workflow terminal event (approved, rejected, withdrawn,
-- cancelled) to keep the source module record's status column in sync.
-- Extend the CASE block as new modules are onboarded.

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_module_code = 'expense_reports' THEN
    UPDATE expense_reports
    SET    status     = p_status::expense_status,
           updated_at = now()
    WHERE  id = p_record_id;

  -- ── Add further modules here as they are onboarded ───────────────────────
  -- ELSIF p_module_code = 'leave_requests' THEN
  --   UPDATE leave_requests SET status = p_status, updated_at = now()
  --   WHERE id = p_record_id;

  ELSE
    RAISE NOTICE 'wf_sync_module_status: unknown module_code %, record unchanged', p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates the status column on the source module record after a workflow '
  'terminal event. Add a new ELSIF branch for each module you onboard.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 6 — CORE RPCs
-- ════════════════════════════════════════════════════════════════════════════

-- ── 6a. wf_advance_instance() (internal) ─────────────────────────────────────
-- Moves an instance to the next step after a step completes (all tasks for the
-- current step are approved). If no more steps remain, completes the instance.
-- Skippable steps (evaluated by wf_evaluate_skip_step) are bypassed
-- automatically. This function is called by wf_approve() — not called directly.

CREATE OR REPLACE FUNCTION wf_advance_instance(
  p_instance_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance     RECORD;
  v_next_step    RECORD;
  v_approver_id  uuid;
  v_due_at       timestamptz;
  v_new_task_id  uuid;
BEGIN
  SELECT id, template_id, current_step, metadata, submitted_by, module_code, record_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  -- Find the next active step after current
  -- Skip any steps where wf_evaluate_skip_step returns true

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

    -- Notify the submitter
    PERFORM wf_queue_notification(
      p_instance_id,
      'wf.completed',
      v_instance.submitted_by,
      jsonb_build_object('module_code', v_instance.module_code)
    );

    -- Sync module record status
    PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'approved');

    RETURN;
  END IF;

  -- ── Resolve approver for next step ────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_next_step.id, p_instance_id);

  IF v_approver_id IS NULL THEN
    -- Cannot route — raise a warning and stall. Admins can reassign.
    RAISE WARNING 'wf_advance_instance: no approver found for step % of instance %',
                  v_next_step.step_order, p_instance_id;
    -- Still advance current_step so the UI shows the correct stage
    UPDATE workflow_instances
    SET    current_step = v_next_step.step_order,
           updated_at   = now()
    WHERE  id = p_instance_id;
    RETURN;
  END IF;

  -- ── Compute SLA deadline ──────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_next_step.sla_hours IS NOT NULL
    THEN now() + (v_next_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create task for next step ─────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (p_instance_id, v_next_step.id, v_next_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_new_task_id;

  -- Advance current_step on the instance
  UPDATE workflow_instances
  SET    current_step = v_next_step.step_order,
         updated_at   = now()
  WHERE  id = p_instance_id;

  -- Log the transition
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order)
  VALUES
    (p_instance_id, v_new_task_id, auth.uid(), 'step_advanced', v_next_step.step_order);

  -- Notify the new assignee
  PERFORM wf_queue_notification(
    p_instance_id,
    'wf.task_assigned',
    v_approver_id,
    jsonb_build_object(
      'step_name',  v_next_step.name,
      'module_code', v_instance.module_code
    )
  );
END;
$$;


-- ── 6b. wf_submit() ──────────────────────────────────────────────────────────
-- Starts a new workflow instance for a module record.
-- p_metadata: caller passes a JSON snapshot of the record at submission time.
-- Returns the new workflow_instance id.

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
  v_template     RECORD;
  v_first_step   RECORD;
  v_instance_id  uuid;
  v_task_id      uuid;
  v_approver_id  uuid;
  v_due_at       timestamptz;
BEGIN
  -- ── Validate template ─────────────────────────────────────────────────────
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

  -- ── Guard: no active workflow already running for this record ─────────────
  IF EXISTS (
    SELECT 1 FROM workflow_instances
    WHERE  module_code = p_module_code
      AND  record_id   = p_record_id
      AND  status      = 'in_progress'
  ) THEN
    RAISE EXCEPTION 'wf_submit: an active workflow already exists for this record';
  END IF;

  -- ── Find first step (skip auto-skip steps) ────────────────────────────────
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

  -- ── Create instance ───────────────────────────────────────────────────────
  INSERT INTO workflow_instances
    (template_id, template_version, module_code, record_id,
     submitted_by, current_step, status, metadata)
  VALUES
    (v_template.id, v_template.version, p_module_code, p_record_id,
     auth.uid(), v_first_step.step_order, 'in_progress', p_metadata)
  RETURNING id INTO v_instance_id;

  -- ── Resolve approver for step 1 ───────────────────────────────────────────
  v_approver_id := wf_resolve_approver(v_first_step.id, v_instance_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'wf_submit: cannot resolve approver for step 1 of template %',
                    p_template_code;
  END IF;

  -- ── SLA deadline ──────────────────────────────────────────────────────────
  v_due_at := CASE
    WHEN v_first_step.sla_hours IS NOT NULL
    THEN now() + (v_first_step.sla_hours * interval '1 hour')
    ELSE NULL
  END;

  -- ── Create first task ─────────────────────────────────────────────────────
  INSERT INTO workflow_tasks
    (instance_id, step_id, step_order, assigned_to, due_at)
  VALUES
    (v_instance_id, v_first_step.id, v_first_step.step_order, v_approver_id, v_due_at)
  RETURNING id INTO v_task_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, metadata)
  VALUES
    (v_instance_id, v_task_id, auth.uid(), 'submitted', v_first_step.step_order,
     jsonb_build_object('template_code', p_template_code));

  -- ── Notify first approver ─────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_instance_id,
    'wf.task_assigned',
    v_approver_id,
    jsonb_build_object(
      'step_name',  v_first_step.name,
      'module_code', p_module_code
    )
  );

  -- ── Sync module status to 'submitted' ─────────────────────────────────────
  PERFORM wf_sync_module_status(p_module_code, p_record_id, 'submitted');

  RETURN v_instance_id;
END;
$$;

COMMENT ON FUNCTION wf_submit(text, text, uuid, jsonb) IS
  'Starts a new workflow instance. Validates the template, creates the instance '
  'with a metadata snapshot, resolves the first approver, creates the first task, '
  'and queues a notification. Returns the new instance id.';


-- ── 6c. wf_approve() ─────────────────────────────────────────────────────────
-- Approve the given task. Only the assigned user (or an admin) may call this.
-- After approval, wf_advance_instance() is called to move to the next step or
-- complete the instance.

CREATE OR REPLACE FUNCTION wf_approve(
  p_task_id uuid,
  p_notes   text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  SELECT t.id, t.instance_id, t.step_id, t.step_order,
         t.assigned_to, t.status
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

  IF v_task.assigned_to != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_approve: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_approve: workflow instance is not in progress (status: %)',
                    v_instance.status;
  END IF;

  -- ── Mark task approved ────────────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'approved',
         notes    = p_notes,
         acted_at = now()
  WHERE  id = p_task_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'approved', v_task.step_order, p_notes);

  -- ── Advance to next step (or complete) ────────────────────────────────────
  PERFORM wf_advance_instance(v_task.instance_id);
END;
$$;

COMMENT ON FUNCTION wf_approve(uuid, text) IS
  'Approves a workflow task. Only the assigned user or an admin may approve. '
  'Advances the instance to the next step or marks it completed.';


-- ── 6d. wf_reject() ──────────────────────────────────────────────────────────
-- Reject the given task. A reason is required. Marks the instance as rejected
-- and syncs the module record status.

CREATE OR REPLACE FUNCTION wf_reject(
  p_task_id uuid,
  p_reason  text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task      RECORD;
  v_instance  RECORD;
BEGIN
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'wf_reject: a rejection reason is required';
  END IF;

  SELECT t.id, t.instance_id, t.step_id, t.step_order, t.assigned_to, t.status
  INTO   v_task
  FROM   workflow_tasks t
  WHERE  t.id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_reject: task % not found', p_task_id;
  END IF;

  IF v_task.status != 'pending' THEN
    RAISE EXCEPTION 'wf_reject: task is not pending (current status: %)', v_task.status;
  END IF;

  IF v_task.assigned_to != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_reject: you are not the assigned approver for this task';
  END IF;

  SELECT id, module_code, record_id, submitted_by, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = v_task.instance_id;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_reject: workflow instance is not in progress';
  END IF;

  -- ── Mark task rejected ────────────────────────────────────────────────────
  UPDATE workflow_tasks
  SET    status   = 'rejected',
         notes    = p_reason,
         acted_at = now()
  WHERE  id = p_task_id;

  -- Cancel all other pending tasks for this instance (shouldn't be any, but
  -- guard against parallel-approver scenarios in future)
  UPDATE workflow_tasks
  SET    status = 'cancelled'
  WHERE  instance_id = v_task.instance_id
    AND  status      = 'pending'
    AND  id         != p_task_id;

  -- ── Mark instance rejected ────────────────────────────────────────────────
  UPDATE workflow_instances
  SET    status       = 'rejected',
         updated_at   = now(),
         completed_at = now()
  WHERE  id = v_task.instance_id;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO workflow_action_log
    (instance_id, task_id, actor_id, action, step_order, notes)
  VALUES
    (v_task.instance_id, p_task_id, auth.uid(), 'rejected', v_task.step_order, p_reason);

  -- ── Notify submitter ──────────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.rejected',
    v_instance.submitted_by,
    jsonb_build_object(
      'reason',      p_reason,
      'module_code', v_instance.module_code
    )
  );

  -- ── Sync module record ────────────────────────────────────────────────────
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'rejected');
END;
$$;

COMMENT ON FUNCTION wf_reject(uuid, text) IS
  'Rejects a workflow task (requires a reason). Marks the instance rejected, '
  'cancels other pending tasks, notifies the submitter, and syncs the module record.';


-- ── 6e. wf_reassign() ────────────────────────────────────────────────────────
-- Reassign a pending task to a different approver (e.g. manual delegation or
-- admin override). The old task is marked 'reassigned' and a new task is
-- created for the new assignee.

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
  v_task      RECORD;
  v_new_task  uuid;
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
    (instance_id, task_id, actor_id, action, step_order, notes,
     metadata)
  VALUES
    (v_task.instance_id, v_new_task, auth.uid(), 'reassigned',
     v_task.step_order, p_reason,
     jsonb_build_object(
       'from_profile', v_task.assigned_to,
       'to_profile',   p_new_profile_id
     ));

  -- ── Notify new assignee ───────────────────────────────────────────────────
  PERFORM wf_queue_notification(
    v_task.instance_id,
    'wf.task_assigned',
    p_new_profile_id,
    jsonb_build_object('step_order', v_task.step_order)
  );
END;
$$;

COMMENT ON FUNCTION wf_reassign(uuid, uuid, text) IS
  'Reassigns a pending task to a new approver. The old task is marked '
  'reassigned (preserved for audit); a new task is created for the new assignee.';


-- ── 6f. wf_withdraw() ────────────────────────────────────────────────────────
-- Allows the submitter to recall/withdraw their in-progress request.

CREATE OR REPLACE FUNCTION wf_withdraw(
  p_instance_id uuid,
  p_reason      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance RECORD;
BEGIN
  SELECT id, submitted_by, module_code, record_id, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_withdraw: instance % not found', p_instance_id;
  END IF;

  IF v_instance.status != 'in_progress' THEN
    RAISE EXCEPTION 'wf_withdraw: only in-progress instances can be withdrawn (status: %)',
                    v_instance.status;
  END IF;

  IF v_instance.submitted_by != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'wf_withdraw: only the submitter or an admin can withdraw';
  END IF;

  -- Cancel pending tasks
  UPDATE workflow_tasks
  SET    status = 'cancelled', acted_at = now()
  WHERE  instance_id = p_instance_id
    AND  status      = 'pending';

  -- Mark instance withdrawn
  UPDATE workflow_instances
  SET    status       = 'withdrawn',
         updated_at   = now(),
         completed_at = now()
  WHERE  id = p_instance_id;

  -- Audit
  INSERT INTO workflow_action_log
    (instance_id, actor_id, action, notes)
  VALUES
    (p_instance_id, auth.uid(), 'withdrawn', p_reason);

  -- Sync module back to 'draft' so the user can edit and resubmit
  PERFORM wf_sync_module_status(v_instance.module_code, v_instance.record_id, 'draft');
END;
$$;

COMMENT ON FUNCTION wf_withdraw(uuid, text) IS
  'Allows the submitter (or admin) to withdraw an in-progress workflow. '
  'Cancels pending tasks and resets the module record to draft status.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 7 — REPORTING VIEWS
-- ════════════════════════════════════════════════════════════════════════════

-- ── 7a. vw_wf_pending_tasks ───────────────────────────────────────────────────
-- Tasks the current user needs to act on. Used to drive the Approver Inbox.

DROP VIEW IF EXISTS vw_wf_pending_tasks;

CREATE VIEW vw_wf_pending_tasks AS
SELECT
  wt.id                  AS task_id,
  wi.id                  AS instance_id,
  wt.assigned_to,
  ws.name                AS step_name,
  wt.step_order,
  tpl.code               AS template_code,
  tpl.name               AS template_name,
  wi.module_code,
  wi.record_id,
  wi.metadata,
  wi.submitted_by,
  e_sub.name             AS submitted_by_name,
  e_sub.business_email   AS submitted_by_email,
  wt.due_at,
  wt.created_at          AS task_created_at,
  CASE
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() THEN 'overdue'
    WHEN wt.due_at IS NOT NULL AND wt.due_at < now() + interval '4 hours' THEN 'due_soon'
    ELSE 'on_track'
  END                    AS sla_status
FROM       workflow_tasks      wt
JOIN       workflow_instances  wi    ON wi.id         = wt.instance_id
JOIN       workflow_steps      ws    ON ws.id         = wt.step_id
JOIN       workflow_templates  tpl   ON tpl.id        = wi.template_id
JOIN       profiles            sub   ON sub.id        = wi.submitted_by
LEFT JOIN  employees           e_sub ON e_sub.id      = sub.employee_id
WHERE      wt.status  = 'pending'
  AND      wi.status  = 'in_progress'
  AND      wt.assigned_to = auth.uid();

COMMENT ON VIEW vw_wf_pending_tasks IS
  'Tasks pending action by the current user. Used to drive the Approver Inbox.';


-- ── 7b. vw_wf_my_requests ─────────────────────────────────────────────────────
-- All workflow instances submitted by the current user, with latest step info.

DROP VIEW IF EXISTS vw_wf_my_requests;

CREATE VIEW vw_wf_my_requests AS
SELECT
  wi.id,
  wi.status,
  wi.module_code,
  wi.record_id,
  tpl.code              AS template_code,
  tpl.name              AS template_name,
  wi.current_step,
  wi.created_at         AS submitted_at,
  wi.updated_at,
  wi.completed_at,
  -- Current pending task details (NULL if completed/rejected)
  current_task.assigned_to   AS current_approver_id,
  e_apr.name                 AS current_approver_name,
  current_task.due_at        AS current_task_due
FROM       workflow_instances  wi
JOIN       workflow_templates  tpl ON tpl.id = wi.template_id
LEFT JOIN  workflow_tasks      current_task
             ON  current_task.instance_id = wi.id
             AND current_task.step_order  = wi.current_step
             AND current_task.status      = 'pending'
LEFT JOIN  profiles            p_apr ON p_apr.id        = current_task.assigned_to
LEFT JOIN  employees           e_apr ON e_apr.id        = p_apr.employee_id
WHERE      wi.submitted_by = auth.uid()
ORDER BY   wi.created_at DESC;

COMMENT ON VIEW vw_wf_my_requests IS
  'All workflow instances submitted by the current user, with current step and '
  'approver information.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 8 — PERMISSIONS SEED
-- ════════════════════════════════════════════════════════════════════════════

-- Ensure the workflow module exists
-- Note: modules table uses (code, name, active, sort_order) — no description column
INSERT INTO modules (code, name, active, sort_order)
VALUES (
  'workflow',
  'Workflow Engine',
  true,
  90
)
ON CONFLICT (code) DO NOTHING;

-- Seed workflow permissions
INSERT INTO permissions (code, name, description, module_id, sort_order)
SELECT
  v.code, v.name, v.description, m.id, v.sort_order
FROM (VALUES
  ('workflow.submit',
   'Submit for Approval',
   'Start a new workflow approval process for a supported module record.',
   10),
  ('workflow.approve',
   'Approve / Reject Tasks',
   'Review and approve or reject workflow tasks assigned to you.',
   20),
  ('workflow.admin',
   'Workflow Administration',
   'Full access to all workflow instances, tasks, templates, and reporting. '
   'Can reassign tasks, cancel instances, and manage delegations.',
   30),
  ('workflow.report_view',
   'View Workflow Reports',
   'Access workflow KPI dashboards and approval performance reports.',
   40)
) AS v(code, name, description, sort_order)
JOIN modules m ON m.code = 'workflow'
ON CONFLICT (code) DO UPDATE
  SET name        = EXCLUDED.name,
      description = EXCLUDED.description;

-- Grant workflow.approve to admin and finance roles (mirrors expense approval model)
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r
CROSS JOIN permissions p
WHERE  r.code IN ('admin', 'finance', 'manager')
  AND  p.code IN ('workflow.submit', 'workflow.approve')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r
CROSS JOIN permissions p
WHERE  r.code = 'admin'
  AND  p.code IN ('workflow.admin', 'workflow.report_view')
ON CONFLICT DO NOTHING;

-- All roles get workflow.submit (ESS employees can submit expense reports etc.)
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM   roles r
CROSS JOIN permissions p
WHERE  p.code = 'workflow.submit'
ON CONFLICT DO NOTHING;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 9 — SEED DATA
-- ════════════════════════════════════════════════════════════════════════════

-- ── 9a. EXPENSE_APPROVAL template ────────────────────────────────────────────

DO $$
DECLARE
  v_template_id  uuid;
  v_step1_id     uuid;
  v_step2_id     uuid;
BEGIN
  -- Upsert template
  INSERT INTO workflow_templates (code, name, description, module_code, is_active, version)
  VALUES (
    'EXPENSE_APPROVAL',
    'Expense Report Approval',
    'Two-stage approval: line manager approval followed by finance sign-off.',
    'expense_reports',
    true,
    1
  )
  ON CONFLICT (code) DO UPDATE
    SET name        = EXCLUDED.name,
        description = EXCLUDED.description,
        updated_at  = now()
  RETURNING id INTO v_template_id;

  -- Step 1: Manager Approval (48-hour SLA)
  INSERT INTO workflow_steps
    (template_id, step_order, name, approver_type, sla_hours, allow_delegation)
  VALUES
    (v_template_id, 1, 'Manager Approval', 'MANAGER', 48, true)
  ON CONFLICT (template_id, step_order) DO UPDATE
    SET name             = EXCLUDED.name,
        approver_type    = EXCLUDED.approver_type,
        sla_hours        = EXCLUDED.sla_hours,
        allow_delegation = EXCLUDED.allow_delegation
  RETURNING id INTO v_step1_id;

  -- Step 2: Finance Approval (72-hour SLA)
  INSERT INTO workflow_steps
    (template_id, step_order, name, approver_type, approver_role, sla_hours, allow_delegation)
  VALUES
    (v_template_id, 2, 'Finance Approval', 'ROLE', 'finance', 72, true)
  ON CONFLICT (template_id, step_order) DO UPDATE
    SET name             = EXCLUDED.name,
        approver_type    = EXCLUDED.approver_type,
        approver_role    = EXCLUDED.approver_role,
        sla_hours        = EXCLUDED.sla_hours,
        allow_delegation = EXCLUDED.allow_delegation
  RETURNING id INTO v_step2_id;

  RAISE NOTICE 'EXPENSE_APPROVAL template seeded: template=% step1=% step2=%',
               v_template_id, v_step1_id, v_step2_id;
END;
$$;


-- ── 9b. Notification message templates ───────────────────────────────────────

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES
  ('wf.task_assigned',
   'New approval task: {{step_name}}',
   'You have a new task waiting for your approval. Please review and act promptly.'),

  ('wf.approved',
   'Step approved — moving to next stage',
   'Your request has been approved at the current step and has been forwarded for the next review.'),

  ('wf.rejected',
   'Request rejected',
   'Your request was rejected. Reason: {{reason}}. Please review the feedback and resubmit if appropriate.'),

  ('wf.completed',
   'Request fully approved',
   'Your request has been approved by all required approvers and is now complete.'),

  ('wf.sla_warning',
   'Approval task due soon',
   'You have an approval task that is due within the next 4 hours. Please act now to avoid a breach.'),

  ('wf.sla_breach',
   'Approval task overdue',
   'An approval task assigned to you has passed its deadline. Please action it immediately.'),

  ('wf.reassigned',
   'Approval task reassigned to you',
   'An approval task has been reassigned to you. Please review it at your earliest convenience.'),

  ('wf.withdrawn',
   'Request withdrawn',
   'The request you were reviewing has been withdrawn by the submitter.')

ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl,
      updated_at = now();


-- ════════════════════════════════════════════════════════════════════════════
-- PART 10 — VERIFICATION
-- ════════════════════════════════════════════════════════════════════════════

-- Tables created
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   LIKE 'workflow%'
ORDER BY table_name;

-- Template + steps seeded
SELECT
  wt.code,
  wt.name       AS template,
  wt.version,
  ws.step_order,
  ws.name       AS step,
  ws.approver_type,
  ws.approver_role,
  ws.sla_hours
FROM workflow_templates wt
JOIN workflow_steps ws ON ws.template_id = wt.id
ORDER BY wt.code, ws.step_order;

-- Notification templates seeded
SELECT code, title_tmpl FROM workflow_notification_templates ORDER BY code;

-- Permissions seeded
SELECT p.code, p.name
FROM permissions p
JOIN modules m ON m.id = p.module_id
WHERE m.code = 'workflow'
ORDER BY p.sort_order;

-- Functions created
SELECT proname
FROM   pg_proc
WHERE  proname LIKE 'wf_%'
ORDER  BY proname;
