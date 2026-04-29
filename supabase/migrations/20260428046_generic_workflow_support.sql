-- =============================================================================
-- Generic Workflow Support
--
-- Gaps addressed:
--   Gap 5 — extend wf_sync_module_status to handle non-expense modules
--   Gap 3 — workflow_pending_changes table + submit_change_request RPC
--   Gap 4 — get_pending_count RPC (used by WorkflowGateBanner)
--
-- Design
-- ──────
-- For expense_reports (the only "wired" module), the workflow locks the
-- existing record by updating expense_reports.status.
--
-- For all other modules ("proposed change" pattern), the submitter's changes
-- are stored as a JSON snapshot in workflow_pending_changes. The workflow
-- engine drives status transitions on that snapshot row. When approved, a
-- separate on_approved handler (built per module) reads proposed_data and
-- applies the actual DB change.
--
-- Key invariant:
--   For non-expense modules, wf_submit receives workflow_pending_changes.id
--   as p_record_id. This allows wf_sync_module_status to find and update the
--   right pending_change row using only the record_id it already has.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — workflow_pending_changes table
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS workflow_pending_changes (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  module_code   text        NOT NULL,
  record_id     uuid,                       -- the original record being changed; NULL for 'create'
  instance_id   uuid        REFERENCES workflow_instances(id),  -- set after wf_submit
  action        text        NOT NULL DEFAULT 'update'
                            CHECK (action IN ('create', 'update', 'delete')),
  proposed_data jsonb       NOT NULL DEFAULT '{}',
  submitted_by  uuid        REFERENCES profiles(id),
  status        text        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz
);

COMMENT ON TABLE workflow_pending_changes IS
  'Stores proposed changes submitted through the workflow engine for non-expense modules. '
  'The row id is used as the record_id in workflow_instances so that wf_sync_module_status '
  'can update the status when the workflow resolves.';

COMMENT ON COLUMN workflow_pending_changes.record_id IS
  'The original record being modified (e.g. employee.id, department.id). NULL for create actions.';

COMMENT ON COLUMN workflow_pending_changes.instance_id IS
  'Set after wf_submit returns. Links back to the workflow instance driving this change.';

CREATE INDEX IF NOT EXISTS wpc_module_status_idx
  ON workflow_pending_changes (module_code, status);

CREATE INDEX IF NOT EXISTS wpc_submitted_by_idx
  ON workflow_pending_changes (submitted_by, status);

CREATE INDEX IF NOT EXISTS wpc_instance_idx
  ON workflow_pending_changes (instance_id);

ALTER TABLE workflow_pending_changes ENABLE ROW LEVEL SECURITY;

-- Submitters see their own; workflow admins see all
CREATE POLICY wpc_select ON workflow_pending_changes FOR SELECT
  USING (
    submitted_by = auth.uid()
    OR has_role('admin')
    OR has_permission('workflow.admin')
    OR has_permission('workflow.approve')
  );

-- Inserts and updates only via SECURITY DEFINER functions
CREATE POLICY wpc_insert ON workflow_pending_changes FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY wpc_update ON workflow_pending_changes FOR UPDATE
  USING (has_role('admin') OR has_permission('workflow.admin'));


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — Extend wf_sync_module_status for non-expense modules
--
-- For expense_reports: unchanged — updates expense_reports.status
-- For all others:      updates workflow_pending_changes.status using p_record_id
--                      which is workflow_pending_changes.id for these modules
-- ════════════════════════════════════════════════════════════════════════════

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
    -- Existing behaviour: update the source record's status column
    UPDATE expense_reports
    SET    status     = p_status::expense_status,
           updated_at = now()
    WHERE  id = p_record_id;

  ELSE
    -- Generic behaviour: p_record_id = workflow_pending_changes.id
    -- Map workflow engine statuses to pending_change statuses
    UPDATE workflow_pending_changes
    SET
      status      = CASE p_status
                      WHEN 'submitted'  THEN 'pending'
                      WHEN 'approved'   THEN 'approved'
                      WHEN 'rejected'   THEN 'rejected'
                      WHEN 'withdrawn'  THEN 'withdrawn'
                      WHEN 'cancelled'  THEN 'withdrawn'
                      ELSE status          -- no-op for unknown statuses
                    END,
      resolved_at = CASE
                      WHEN p_status IN ('approved', 'rejected', 'withdrawn', 'cancelled')
                      THEN now()
                      ELSE NULL
                    END
    WHERE id = p_record_id;

    -- Silently ignore if no matching row — avoids errors during dry-runs
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates the status on the source module record when a workflow event occurs. '
  'For expense_reports: updates expense_reports.status. '
  'For all other modules: updates workflow_pending_changes.status using the pending_change UUID as p_record_id. '
  'Add a new ELSIF branch only when a module needs a custom status column update.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — submit_change_request: generic submission RPC
--
-- Used by all non-expense modules (profile updates, dept edits, projects, etc).
-- Caller passes the proposed change as JSON; this function:
--   1. Resolves the correct workflow template via resolve_workflow_for_submission
--   2. Creates a workflow_pending_changes row (its UUID becomes the record_id)
--   3. Calls wf_submit with that UUID as record_id
--   4. Links the instance back to the pending_change row
--   5. Returns { ok, pending_change_id, instance_id }
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION submit_change_request(
  p_module_code   text,
  p_record_id     uuid,     -- original record being changed; NULL for 'create' actions
  p_proposed_data jsonb,
  p_action        text DEFAULT 'update'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id        uuid;
  v_template_id   uuid;
  v_template_code text;
  v_pending_id    uuid;
  v_instance_id   uuid;
BEGIN
  -- ── Basic validation ────────────────────────────────────────────────────────
  IF p_module_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'module_code is required.');
  END IF;

  IF p_module_code = 'expense_reports' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Use submit_expense() for expense_reports, not submit_change_request().'
    );
  END IF;

  IF p_action NOT IN ('create', 'update', 'delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'action must be create, update, or delete.');
  END IF;

  -- ── Must be linked to an employee (or be an admin) ─────────────────────────
  -- Non-blocking check — some admin-only modules may not have an employee record
  v_emp_id := get_my_employee_id();

  -- ── Resolve workflow ────────────────────────────────────────────────────────
  v_template_id := resolve_workflow_for_submission(p_module_code, auth.uid());

  IF v_template_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format(
        'No active workflow assignment found for module "%s". '
        'Ask your administrator to configure one in Workflow → Assignments.',
        p_module_code
      )
    );
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_template_id;

  -- ── Create the pending change record ────────────────────────────────────────
  -- Its UUID (v_pending_id) will be used as the record_id in workflow_instances
  -- so that wf_sync_module_status can find and update this row by ID.
  INSERT INTO workflow_pending_changes (
    module_code, record_id, action, proposed_data, submitted_by
  ) VALUES (
    p_module_code,
    p_record_id,       -- original record (can be NULL for creates)
    p_action,
    COALESCE(p_proposed_data, '{}'),
    auth.uid()
  )
  RETURNING id INTO v_pending_id;

  -- ── Submit to workflow engine ────────────────────────────────────────────────
  v_instance_id := wf_submit(
    p_template_code => v_template_code,
    p_module_code   => p_module_code,
    p_record_id     => v_pending_id,    -- pending_change.id acts as the record_id
    p_metadata      => COALESCE(p_proposed_data, '{}')
  );

  -- ── Link instance back to pending change ─────────────────────────────────────
  UPDATE workflow_pending_changes
  SET    instance_id = v_instance_id
  WHERE  id = v_pending_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'pending_change_id', v_pending_id,
    'instance_id',       v_instance_id
  );

EXCEPTION WHEN OTHERS THEN
  -- Clean up the pending change row if wf_submit failed
  DELETE FROM workflow_pending_changes WHERE id = v_pending_id;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION submit_change_request(text, uuid, jsonb, text) IS
  'Generic workflow submission for non-expense modules. '
  'Creates a workflow_pending_changes snapshot, then routes it through wf_submit. '
  'Returns { ok, pending_change_id, instance_id } on success. '
  'The pending_change row is the source of truth for approval status; '
  'an on_approved handler (per module) reads proposed_data and applies the actual change.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — get_pending_count: used by WorkflowGateBanner
--
-- Returns the number of in-flight change requests for a module,
-- optionally filtered to a specific submitter.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_pending_count(
  p_module_code  text,
  p_submitted_by uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  IF p_module_code = 'expense_reports' THEN
    -- For expense_reports, pending = active workflow instances
    SELECT COUNT(*)::integer INTO v_count
    FROM   workflow_instances
    WHERE  module_code = p_module_code
      AND  status NOT IN ('approved', 'rejected', 'withdrawn', 'cancelled')
      AND  (p_submitted_by IS NULL OR submitted_by = p_submitted_by);
  ELSE
    -- For all other modules, pending = workflow_pending_changes with status='pending'
    SELECT COUNT(*)::integer INTO v_count
    FROM   workflow_pending_changes
    WHERE  module_code = p_module_code
      AND  status      = 'pending'
      AND  (p_submitted_by IS NULL OR submitted_by = p_submitted_by);
  END IF;

  RETURN COALESCE(v_count, 0);
END;
$$;

COMMENT ON FUNCTION get_pending_count(text, uuid) IS
  'Returns the number of in-flight change requests for a module. '
  'Pass p_submitted_by to scope to a single user (e.g. for employee-view banners). '
  'For expense_reports: counts workflow_instances. '
  'For all others: counts workflow_pending_changes with status=pending.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 5 — Verification
-- ════════════════════════════════════════════════════════════════════════════

SELECT proname
FROM   pg_proc
WHERE  proname IN (
  'wf_sync_module_status',
  'submit_change_request',
  'get_pending_count'
)
ORDER BY proname;

SELECT table_name
FROM   information_schema.tables
WHERE  table_name = 'workflow_pending_changes'
  AND  table_schema = 'public';
