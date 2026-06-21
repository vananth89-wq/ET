-- Migration 530: Fix get_workflow_instance_routing status values + add approvedByName
--
-- Bug: RPC was returning status values 'approved'/'skipped'/'upcoming'/'pending'
-- but WorkflowParticipantsModal checks for 'completed'/'active'/'pending'.
-- Result: completed steps (e.g. Vijey's approval) showed orange "Awaiting approval"
-- instead of green "Approved".
--
-- Fix:
--   approved  → completed
--   skipped   → completed  (skipped steps are done, not blocking)
--   pending   → active     (currently awaiting action)
--   upcoming  → pending    (not yet reached)
--
-- Also adds approvedByName (actor name from workflow_action_log) which was
-- missing — "Approved by X" line in the modal was never showing.

CREATE OR REPLACE FUNCTION get_workflow_instance_routing(p_instance_id uuid)
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
  SELECT submitted_by, template_id, subject_profile_id
  INTO   v_instance
  FROM   workflow_instances
  WHERE  id = p_instance_id;

  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',    ws.step_order,
      'stepName',     ws.name,
      'approverType', ws.approver_type,
      'approverRole', ws.approver_role,
      'slaHours',     ws.sla_hours,
      'isCC',         ws.is_cc,
      'approvalMode', ws.approval_mode,

      -- ── status (mapped to frontend values) ────────────────────────────────
      -- 'completed' = done (approved or skipped)
      -- 'active'    = currently awaiting action
      -- 'pending'   = not yet reached
      'status', (
        SELECT CASE
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE  wt.instance_id = p_instance_id
              AND  wt.step_order  = ws.step_order
              AND  wt.status IN ('approved', 'skipped')
          ) THEN 'completed'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE  wt.instance_id = p_instance_id
              AND  wt.step_order  = ws.step_order
              AND  wt.status = 'pending'
          ) THEN 'active'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE  wt.instance_id = p_instance_id
              AND  wt.step_order  = ws.step_order
              AND  wt.status = 'rejected'
          ) THEN 'rejected'
          ELSE 'pending'
        END
      ),

      -- ── approvedAt ─────────────────────────────────────────────────────────
      'approvedAt', (
        SELECT wal.created_at
        FROM   workflow_action_log wal
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      -- ── approvedByName ─────────────────────────────────────────────────────
      'approvedByName', (
        SELECT emp.name
        FROM   workflow_action_log wal
        JOIN   profiles  p   ON p.id  = wal.actor_id
        JOIN   employees emp ON emp.id = p.employee_id
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      -- ── resolvedName ──────────────────────────────────────────────────────
      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name, 'Dept. Head')
          WHEN 'ROLE' THEN
            CASE
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
              ELSE COALESCE(role_row.name, ws.approver_role)
            END
          WHEN 'SELF'             THEN COALESCE(self_emp.name, 'You')
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.name, 'Employee')
          ELSE ws.name
        END,

      -- ── resolvedDesignation ───────────────────────────────────────────────
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE' THEN
            CASE
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
              ELSE CASE WHEN ws.approval_mode = 'ALL_OF'
                        THEN 'All active members must approve'
                        ELSE 'All active members — first to approve wins'
                   END
            END
          WHEN 'SELF'             THEN NULL
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.job_title, 'Subject Employee')
          ELSE NULL
        END,

      -- ── roleMembers ───────────────────────────────────────────────────────
      'roleMembers',
        CASE ws.approver_type
          WHEN 'ROLE' THEN (
            CASE WHEN EXISTS (
              SELECT 1 FROM workflow_tasks wt
              WHERE wt.instance_id = p_instance_id
                AND wt.step_order  = ws.step_order
                AND wt.status NOT IN ('skipped')
            )
            THEN (
              SELECT jsonb_agg(
                jsonb_build_object('name', emp.name, 'jobTitle', emp.job_title)
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

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   profiles  sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by)
    LIMIT  1
  ) subject_emp ON ws.approver_type = 'SUBJECT_EMPLOYEE'

  WHERE ws.template_id = v_instance.template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_instance_routing(uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_instance_routing(uuid) IS
  'Mig 530: status values now map to frontend vocabulary: '
  'completed (was approved/skipped), active (was pending), pending (was upcoming). '
  'Added approvedByName for "Approved by X" display in WorkflowParticipantsModal.';
