-- =============================================================================
-- Migration 069: SECURITY DEFINER RPCs for workflow instance reads
--
-- Problem: useWorkflowInstance does a direct PostgREST SELECT on
--   workflow_instances with an embedded workflow_templates join.
--   This query returns HTTP 500 (internal server error) for all users.
--   The 500 is caused by PostgREST's embedded-resource resolution becoming
--   ambiguous: workflow_instances_template_id_fkey resolves to BOTH the
--   workflow_templates table and the vw_wf_operations view — PostgREST
--   crashes when it cannot pick a unique path.
--
-- Fix: Replace the direct table + embed query with SECURITY DEFINER functions
--   that run plain SQL (no PostgREST resource embedding, no RLS evaluation).
--   Access rules are enforced inside each function:
--     • submitter  — submitted_by = auth.uid()
--     • approver   — has a task assigned to auth.uid() on this instance
--     • admin/mgr  — has expense.view_org / view_team / view_direct permission
--
-- Callers:
--   useWorkflowInstance — used by ReportDetail (employee), WorkflowReview
--   (approver full-page), and ApproverInbox (approver detail panel).
-- =============================================================================


-- ── Helper: can the calling user see this workflow instance? ──────────────────
-- Returns true if:
--   1. They submitted it
--   2. They are (or were) assigned a task on it
--   3. They hold a view-level expense permission (manager / admin)
CREATE OR REPLACE FUNCTION _wf_instance_visible(p_instance_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    -- submitter
    EXISTS (
      SELECT 1 FROM workflow_instances
      WHERE id = p_instance_id AND submitted_by = auth.uid()
    )
    OR
    -- assigned approver (current or historical)
    EXISTS (
      SELECT 1 FROM workflow_tasks
      WHERE instance_id = p_instance_id AND assigned_to = auth.uid()
    )
    OR
    -- broad view permissions (managers, admins)
    has_permission('expense.view_org')
    OR has_permission('expense.view_team')
    OR has_permission('expense.view_direct')
    OR has_permission('workflow.admin');
$$;


-- ── 1. get_my_workflow_instance ───────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_workflow_instance(text, uuid);

CREATE OR REPLACE FUNCTION get_my_workflow_instance(
  p_module_code text,
  p_record_id   uuid
)
RETURNS TABLE (
  id               uuid,
  template_id      uuid,
  template_code    text,
  template_name    text,
  module_code      text,
  record_id        uuid,
  submitted_by     uuid,
  current_step     integer,
  status           text,
  metadata         jsonb,
  created_at       timestamptz,
  updated_at       timestamptz,
  completed_at     timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    wi.id,
    wi.template_id,
    wt.code        AS template_code,
    wt.name        AS template_name,
    wi.module_code,
    wi.record_id,
    wi.submitted_by,
    wi.current_step,
    wi.status,
    wi.metadata,
    wi.created_at,
    wi.updated_at,
    wi.completed_at
  FROM workflow_instances wi
  JOIN workflow_templates  wt ON wt.id = wi.template_id
  WHERE wi.module_code = p_module_code
    AND wi.record_id   = p_record_id
    AND _wf_instance_visible(wi.id)
  ORDER BY wi.created_at DESC
  LIMIT 1;
$$;

COMMENT ON FUNCTION get_my_workflow_instance(text, uuid) IS
  'Returns the most recent visible workflow instance for a module record. '
  'Visible = submitter, assigned approver, or holder of a view permission. '
  'SECURITY DEFINER avoids PostgREST 500 from ambiguous FK embedding.';


-- ── 2. get_my_workflow_tasks ──────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_workflow_tasks(uuid);

CREATE OR REPLACE FUNCTION get_my_workflow_tasks(
  p_instance_id uuid
)
RETURNS TABLE (
  id            uuid,
  step_id       uuid,
  step_order    integer,
  step_name     text,
  assigned_to   uuid,
  assignee_name text,
  status        text,
  notes         text,
  due_at        timestamptz,
  acted_at      timestamptz,
  created_at    timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    wt.id,
    wt.step_id,
    wt.step_order,
    ws.name              AS step_name,
    wt.assigned_to,
    e.name               AS assignee_name,
    wt.status,
    wt.notes,
    wt.due_at,
    wt.acted_at,
    wt.created_at
  FROM workflow_tasks         wt
  JOIN workflow_steps          ws  ON ws.id  = wt.step_id
  LEFT JOIN profiles           p   ON p.id   = wt.assigned_to
  LEFT JOIN employees          e   ON e.id   = p.employee_id
  WHERE wt.instance_id = p_instance_id
    AND _wf_instance_visible(p_instance_id)
  ORDER BY wt.step_order ASC, wt.created_at ASC;
$$;

COMMENT ON FUNCTION get_my_workflow_tasks(uuid) IS
  'Returns tasks for a visible workflow instance. Access-gated by _wf_instance_visible().';


-- ── 3. get_my_workflow_action_log ────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_workflow_action_log(uuid);

CREATE OR REPLACE FUNCTION get_my_workflow_action_log(
  p_instance_id uuid
)
RETURNS TABLE (
  id         uuid,
  actor_id   uuid,
  actor_name text,
  action     text,
  step_order integer,
  notes      text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    wal.id,
    wal.actor_id,
    e.name               AS actor_name,
    wal.action,
    wal.step_order,
    wal.notes,
    wal.created_at
  FROM workflow_action_log     wal
  LEFT JOIN profiles           p   ON p.id  = wal.actor_id
  LEFT JOIN employees          e   ON e.id  = p.employee_id
  WHERE wal.instance_id = p_instance_id
    AND _wf_instance_visible(p_instance_id)
  ORDER BY wal.created_at ASC;
$$;

COMMENT ON FUNCTION get_my_workflow_action_log(uuid) IS
  'Returns action log for a visible workflow instance. Access-gated by _wf_instance_visible().';


-- ── VERIFICATION ──────────────────────────────────────────────────────────────
SELECT routine_name, security_type
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name IN (
    '_wf_instance_visible',
    'get_my_workflow_instance',
    'get_my_workflow_tasks',
    'get_my_workflow_action_log'
  )
ORDER BY routine_name;
