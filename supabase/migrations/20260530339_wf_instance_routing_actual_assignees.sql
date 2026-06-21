-- =============================================================================
-- Migration 339 — get_workflow_instance_routing: show actual task assignees
-- =============================================================================
--
-- PROBLEM
-- ───────
-- For ROLE steps, roleMembers and resolvedName are always read from the role
-- definition (user_roles), never from workflow_tasks. When an approver
-- reassigns a task to someone outside the role (e.g. Hari replaces Naveen),
-- the employee's "View approval progress" modal still shows the original role
-- members, misleading them about who is actually reviewing their request.
--
-- FIX
-- ───
-- For each step, if there are active or completed workflow_tasks for that step
-- on this instance, use the actual task assignees instead of the role members.
-- This reflects the live state: reassignments, delegations, and fan-out all
-- show the real people.
--
-- RULE
--   • active/pending steps: show current pending task assignees
--   • completed steps: show who acted (approvedByName already handles this for
--     the label — but roleMembers tooltip also needs updating)
--   • If no tasks exist yet for a step (future steps), fall back to role members
--
-- resolvedName for ROLE steps:
--   • 1 actual assignee → their name
--   • 2+ actual assignees → role name (same as before, but tooltip is accurate)
--   • No tasks yet → role name (unchanged)
-- =============================================================================

CREATE OR REPLACE FUNCTION get_workflow_instance_routing(
  p_instance_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_instance  RECORD;
  v_result    jsonb;
BEGIN
  SELECT id, template_id, submitted_by, current_step, status
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'get_workflow_instance_routing: instance % not found', p_instance_id;
  END IF;

  -- Access: submitter OR any past/present task holder on this instance
  IF NOT (
    v_instance.submitted_by = auth.uid()
    OR is_super_admin()
    OR EXISTS (
      SELECT 1 FROM workflow_tasks
      WHERE  instance_id  = p_instance_id
        AND  assigned_to  = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM workflow_action_log
      WHERE  instance_id = p_instance_id
        AND  actor_id    = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'get_workflow_instance_routing: access denied';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',    ws.step_order,
      'stepName',     ws.name,
      'approverType', ws.approver_type,
      'approverRole', ws.approver_role,
      'isCC',         COALESCE(ws.is_cc, false),
      'approvalMode', ws.approval_mode,

      -- ── Live step status ──────────────────────────────────────────────────
      'status',
        CASE
          WHEN v_instance.status = 'approved'                                  THEN 'completed'
          WHEN ws.step_order < v_instance.current_step                         THEN 'completed'
          WHEN ws.step_order = v_instance.current_step
           AND v_instance.status IN ('in_progress', 'awaiting_clarification')  THEN 'active'
          ELSE 'pending'
        END,

      -- ── Who approved this step (most recent) ─────────────────────────────
      'approvedByName', (
        SELECT emp.name
        FROM   workflow_action_log wal
        JOIN   profiles            p   ON p.id  = wal.actor_id
        JOIN   employees           emp ON emp.id = p.employee_id
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      'approvedAt', (
        SELECT wal.created_at
        FROM   workflow_action_log wal
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      -- ── resolvedName: use actual assignee when available ──────────────────
      -- For ROLE steps with actual tasks, show the real person's name if there
      -- is exactly one assignee; otherwise fall back to the role name.
      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name, 'Dept. Head')
          WHEN 'ROLE' THEN
            CASE
              -- Single actual task assignee → show their name
              WHEN (SELECT COUNT(*) FROM workflow_tasks wt
                    WHERE wt.instance_id = p_instance_id
                      AND wt.step_order  = ws.step_order
                      AND wt.status NOT IN ('skipped')) = 1
              THEN (
                SELECT emp.name
                FROM   workflow_tasks wt
                JOIN   profiles  p   ON p.id  = wt.assigned_to
                JOIN   employees emp ON emp.id = p.employee_id
                WHERE  wt.instance_id = p_instance_id
                  AND  wt.step_order  = ws.step_order
                  AND  wt.status NOT IN ('skipped')
                LIMIT  1
              )
              -- Multiple or no tasks → role name
              ELSE COALESCE(role_row.name, ws.approver_role)
            END
          WHEN 'SELF' THEN COALESCE(self_emp.name, 'You')
          ELSE ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE' THEN
            CASE
              -- Single actual assignee → show their job title
              WHEN (SELECT COUNT(*) FROM workflow_tasks wt
                    WHERE wt.instance_id = p_instance_id
                      AND wt.step_order  = ws.step_order
                      AND wt.status NOT IN ('skipped')) = 1
              THEN (
                SELECT emp.job_title
                FROM   workflow_tasks wt
                JOIN   profiles  p   ON p.id  = wt.assigned_to
                JOIN   employees emp ON emp.id = p.employee_id
                WHERE  wt.instance_id = p_instance_id
                  AND  wt.step_order  = ws.step_order
                  AND  wt.status NOT IN ('skipped')
                LIMIT  1
              )
              -- Multiple assignees → approval mode description
              ELSE CASE WHEN ws.approval_mode = 'ALL_OF'
                        THEN 'All active members must approve'
                        ELSE 'All active members — first to approve wins'
                   END
            END
          WHEN 'SELF' THEN NULL
          ELSE NULL
        END,

      -- ── roleMembers: actual task assignees when tasks exist, else role def ──
      -- This is the key fix: when tasks have been created (and possibly
      -- reassigned), show those real people — not the role definition.
      'roleMembers',
        CASE ws.approver_type
          WHEN 'ROLE' THEN (
            -- If tasks exist for this step on this instance, use them
            CASE WHEN EXISTS (
              SELECT 1 FROM workflow_tasks wt
              WHERE wt.instance_id = p_instance_id
                AND wt.step_order  = ws.step_order
                AND wt.status NOT IN ('skipped')
            )
            THEN (
              -- Actual task assignees (respects reassignments)
              SELECT jsonb_agg(
                jsonb_build_object(
                  'name',     emp.name,
                  'jobTitle', emp.job_title
                )
                ORDER BY emp.name
              )
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status NOT IN ('skipped')
            )
            ELSE (
              -- No tasks yet (future step) — show role definition members
              SELECT jsonb_agg(
                jsonb_build_object('name', emp.name, 'jobTitle', emp.job_title)
                ORDER BY emp.name
              )
              FROM   user_roles ur
              JOIN   roles      r   ON r.id  = ur.role_id
              JOIN   profiles   p   ON p.id  = ur.profile_id
              JOIN   employees  emp ON emp.id = p.employee_id
              WHERE  r.code       = ws.approver_role
                AND  r.active     = true
                AND  ur.is_active = true
                AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
            )
            END
          )
          ELSE NULL::jsonb
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles    pr
    JOIN   employees   emp ON emp.id = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  LEFT JOIN LATERAL (
    SELECT r.name
    FROM   roles r
    WHERE  r.code = ws.approver_role AND r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type = 'ROLE'

  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles  sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  sp.id = v_instance.submitted_by
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')

  LEFT JOIN LATERAL (
    SELECT emp.name
    FROM   profiles  sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = v_instance.submitted_by
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'

  WHERE ws.template_id = v_instance.template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_instance_routing(uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_instance_routing(uuid) IS
  'Returns live routing chain for a workflow instance. '
  'Mig 339: ROLE step roleMembers now shows actual workflow_tasks assignees when '
  'tasks exist (respects reassignments and delegations). Falls back to role '
  'definition members for future steps with no tasks yet. resolvedName for a '
  'single-assignee ROLE step shows that person''s name directly.';
