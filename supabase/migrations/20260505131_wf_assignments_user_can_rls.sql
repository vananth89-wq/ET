-- =============================================================================
-- Migration 131: Upgrade workflow_tasks, workflow_assignments &
--                workflow_assignment_audit RLS to user_can()
--
-- TABLES COVERED
-- ──────────────
--   workflow_tasks            — individual approval tasks assigned to approvers
--   workflow_assignments      — template-to-entity routing rules
--   workflow_assignment_audit — immutable log of assignment changes (trigger-written)
--
-- POLICIES CHANGED
-- ────────────────
--   workflow_tasks:
--     wf_tasks_select  — replaces has_role + has_permission with user_can view
--     wf_tasks_admin   — FOR ALL dropped; replaced with explicit write policies
--
--   workflow_assignments:
--     wa_select        — unchanged (auth.uid() IS NOT NULL — needed for submission)
--     wa_admin         — FOR ALL dropped; replaced with explicit write policies
--
--   workflow_assignment_audit:
--     waa_admin        — FOR ALL dropped; replaced with SELECT-only admin read
--                        (rows are written exclusively by SECURITY DEFINER trigger)
-- =============================================================================


-- ── 1. Seed wf_assignments.edit permission ────────────────────────────────────

INSERT INTO permissions (code, name, description, module_id, action)
SELECT
  'wf_assignments.edit'                                                  AS code,
  'Manage Workflow Assignments'                                          AS name,
  'Grants create / update / delete access to workflow assignment rules' AS description,
  m.id                                                                   AS module_id,
  'edit'                                                                 AS action
FROM modules m
WHERE m.code = 'wf_assignments'
ON CONFLICT (code) DO UPDATE
  SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    module_id   = EXCLUDED.module_id,
    action      = EXCLUDED.action;


-- ── 2. workflow_tasks ─────────────────────────────────────────────────────────

DROP POLICY IF EXISTS wf_tasks_select ON workflow_tasks;
DROP POLICY IF EXISTS wf_tasks_admin  ON workflow_tasks;

-- Assignee + submitter of the parent instance always see their tasks.
-- wf_assignments.view holders (Workflow Admin) see all tasks.
CREATE POLICY wf_tasks_select ON workflow_tasks FOR SELECT
  USING (
    assigned_to = auth.uid()
    OR user_can('wf_assignments', 'view', NULL)
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.id = workflow_tasks.instance_id
        AND wi.submitted_by = auth.uid()
    )
  );

CREATE POLICY wf_tasks_insert ON workflow_tasks
  FOR INSERT
  WITH CHECK (user_can('wf_assignments', 'edit', NULL));

CREATE POLICY wf_tasks_update ON workflow_tasks
  FOR UPDATE
  USING      (user_can('wf_assignments', 'edit', NULL))
  WITH CHECK (user_can('wf_assignments', 'edit', NULL));

CREATE POLICY wf_tasks_delete ON workflow_tasks
  FOR DELETE
  USING (user_can('wf_assignments', 'edit', NULL));


-- ── 3. workflow_assignments ───────────────────────────────────────────────────

DROP POLICY IF EXISTS wa_admin ON workflow_assignments;
-- wa_select (auth.uid() IS NOT NULL) is unchanged — open reads needed during
-- workflow submission to resolve the correct template for a given entity.

CREATE POLICY wa_insert ON workflow_assignments
  FOR INSERT
  WITH CHECK (user_can('wf_assignments', 'edit', NULL));

CREATE POLICY wa_update ON workflow_assignments
  FOR UPDATE
  USING      (user_can('wf_assignments', 'edit', NULL))
  WITH CHECK (user_can('wf_assignments', 'edit', NULL));

CREATE POLICY wa_delete ON workflow_assignments
  FOR DELETE
  USING (user_can('wf_assignments', 'edit', NULL));


-- ── 4. workflow_assignment_audit ──────────────────────────────────────────────
-- Rows are written exclusively by a SECURITY DEFINER trigger — no INSERT /
-- UPDATE / DELETE RLS policy is needed. Tighten to admin-read only.

DROP POLICY IF EXISTS waa_admin ON workflow_assignment_audit;

CREATE POLICY waa_select ON workflow_assignment_audit FOR SELECT
  USING (user_can('wf_assignments', 'view', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN (
  'workflow_tasks', 'workflow_assignments', 'workflow_assignment_audit'
)
ORDER BY tablename, cmd, policyname;

SELECT code, name, action
FROM   permissions
WHERE  code IN ('wf_assignments.view', 'wf_assignments.edit')
ORDER  BY code;
