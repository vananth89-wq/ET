-- =============================================================================
-- Migration 586: Fix get_workflow_instance_routing — MANAGER name via subject
--
-- Mig 585 tried to read the manager name from workflow_tasks.assigned_to.
-- This fails when the MANAGER step was skipped at submission (no active task,
-- or task with status='skipped' which is excluded by the NOT IN filter).
--
-- Better approach: resolve the manager by walking
--   subject_profile_id → employee → manager_id → manager name
-- subject_profile_id is the terminated/subject employee's profile, set correctly
-- since mig 583 (p_subject_employee_id fix in submit_termination / wf_submit).
--
-- For self-service workflows (submitter = subject), subject_profile_id = submitted_by,
-- so the behavior is identical to the original mig 530 logic.
-- For admin-submitted workflows (termination), it now walks the SUBJECT's manager
-- instead of the SUBMITTER's manager — giving Safia instead of "Direct Manager".
-- =============================================================================

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

      -- ── status ────────────────────────────────────────────────────────────
      -- 'skipped' is returned separately from 'completed' so the UI can
      -- distinguish a step that was auto-skipped (e.g. manager = submitter)
      -- from one that was explicitly approved.
      'status', (
        SELECT CASE
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE  wt.instance_id = p_instance_id
              AND  wt.step_order  = ws.step_order
              AND  wt.status = 'approved'
          ) THEN 'completed'
          WHEN EXISTS (
            SELECT 1 FROM workflow_tasks wt
            WHERE  wt.instance_id = p_instance_id
              AND  wt.step_order  = ws.step_order
              AND  wt.status = 'skipped'
          ) THEN 'skipped'
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

      -- ── approvedAt ────────────────────────────────────────────────────────
      'approvedAt', (
        SELECT wal.created_at
        FROM   workflow_action_log wal
        WHERE  wal.instance_id = p_instance_id
          AND  wal.step_order  = ws.step_order
          AND  wal.action      = 'approved'
        ORDER  BY wal.created_at DESC
        LIMIT  1
      ),

      -- ── approvedByName ────────────────────────────────────────────────────
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
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name,     'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name,     'Dept. Head')
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
          WHEN 'SELF'             THEN COALESCE(self_emp.name,    'You')
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.name, 'Employee')
          ELSE ws.name
        END,

      -- ── resolvedDesignation ───────────────────────────────────────────────
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN mgr_emp.job_title
          WHEN 'DEPT_HEAD'     THEN mgr_emp.job_title
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

  -- ── MANAGER / DEPT_HEAD: resolve via subject employee's manager ───────────
  -- Walk: subject_profile_id → subject employee → manager_id → manager name.
  -- subject_profile_id = the terminated/subject employee's profile (set by wf_submit
  -- via p_subject_employee_id). Falls back to submitted_by for self-service flows
  -- where submitter = subject, preserving original mig 530 behaviour.
  -- This correctly shows Safia for terminations submitted by an admin on behalf
  -- of Abdul Malik, instead of resolving the submitter's (Vijey's) manager.
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title
    FROM   profiles  sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    WHERE  sp.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by)
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
  'Mig 586: MANAGER/DEPT_HEAD resolvedName now walks subject_profile_id → manager '
  'instead of submitted_by → manager. Fixes blank manager name for admin-submitted '
  'workflows (termination) where submitter ≠ subject. Works for skipped manager '
  'steps too since it reads from employees, not workflow_tasks.';
