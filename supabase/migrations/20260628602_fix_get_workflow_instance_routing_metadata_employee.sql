-- =============================================================================
-- Migration 602: get_workflow_instance_routing — use metadata.employee_id for
--                MANAGER/DEPT_HEAD resolution
--
-- Root cause of the "Direct Manager" fallback showing on old instances:
--
--   Mig 583 introduced p_subject_employee_id → subject_profile_id on wf_submit,
--   but instances submitted BEFORE mig 583 have subject_profile_id = auth.uid()
--   (the admin who submitted, e.g., Vijey). Vijey has no manager, so the lateral
--   join (subject_profile_id → employee → manager_id) returns null → 'Direct Manager'.
--
--   Mig 601 added a task-assignment fallback, but for those old instances the
--   MANAGER step was also completely bypassed at submission (wf_resolve_approver
--   returned null for admin → step skipped, no task created). So the task fallback
--   also returns null.
--
-- The reliable fix:
--   All module RPCs (submit_termination, etc.) have always stored
--   metadata->>'employee_id' = the actual subject employee's ID.
--   Use this as the primary source for MANAGER/DEPT_HEAD resolution,
--   falling back to the profile chain for older or non-module workflows.
--
-- Resolution priority for MANAGER/DEPT_HEAD lateral join:
--   1. metadata->>'employee_id'  — explicit subject employee (always accurate)
--   2. subject_profile_id → employee — correct for self-service post-mig 583
--   3. submitted_by → employee — original self-service fallback
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
  SELECT submitted_by, template_id, subject_profile_id, metadata
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

          WHEN 'MANAGER' THEN COALESCE(
            -- 1. Best: org-chart walk from resolved subject employee
            mgr_emp.name,
            -- 2. Fallback: actual task assignment (handles mid-submission state)
            (
              SELECT emp.name
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status     != 'skipped'
              LIMIT  1
            ),
            'Direct Manager'
          )

          WHEN 'DEPT_HEAD' THEN COALESCE(
            mgr_emp.name,
            (
              SELECT emp.name
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status     != 'skipped'
              LIMIT  1
            ),
            'Dept. Head'
          )

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

          WHEN 'MANAGER' THEN COALESCE(
            mgr_emp.job_title,
            (
              SELECT emp.job_title
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status     != 'skipped'
              LIMIT  1
            )
          )

          WHEN 'DEPT_HEAD' THEN COALESCE(
            mgr_emp.job_title,
            (
              SELECT emp.job_title
              FROM   workflow_tasks wt
              JOIN   profiles  p   ON p.id  = wt.assigned_to
              JOIN   employees emp ON emp.id = p.employee_id
              WHERE  wt.instance_id = p_instance_id
                AND  wt.step_order  = ws.step_order
                AND  wt.status     != 'skipped'
              LIMIT  1
            )
          )

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

  -- ── MANAGER / DEPT_HEAD: walk subject employee → manager ──────────────────
  -- Resolution priority for subject employee ID:
  --   1. metadata->>'employee_id'  — set by every module submit RPC (always accurate)
  --   2. subject_profile_id → employee  — correct for self-service post-mig 583
  --   3. submitted_by → employee  — original self-service fallback
  --
  -- This correctly handles old instances (pre-mig 583) where subject_profile_id
  -- was set to the admin's profile (submitted_by) — those instances still have
  -- metadata.employee_id pointing to the actual subject employee.
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title
    FROM   employees se
    JOIN   employees mgr ON mgr.id = se.manager_id
    WHERE  se.id = COALESCE(
      -- 1. metadata.employee_id (termination, employment, personal_info, etc.)
      NULLIF(v_instance.metadata->>'employee_id', '')::uuid,
      -- 2. subject_profile_id → employee (self-service post-mig 583)
      (
        SELECT e.id FROM profiles sp
        JOIN   employees e ON e.id = sp.employee_id
        WHERE  sp.id = v_instance.subject_profile_id
          AND  v_instance.subject_profile_id IS NOT NULL
        LIMIT  1
      ),
      -- 3. submitted_by → employee (original self-service fallback)
      (
        SELECT e.id FROM profiles sp
        JOIN   employees e ON e.id = sp.employee_id
        WHERE  sp.id = v_instance.submitted_by
        LIMIT  1
      )
    )
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
    FROM   employees emp
    WHERE  emp.id = COALESCE(
      NULLIF(v_instance.metadata->>'employee_id', '')::uuid,
      (
        SELECT e.id FROM profiles sp
        JOIN   employees e ON e.id = sp.employee_id
        WHERE  sp.id = COALESCE(v_instance.subject_profile_id, v_instance.submitted_by)
        LIMIT  1
      )
    )
    LIMIT  1
  ) subject_emp ON ws.approver_type = 'SUBJECT_EMPLOYEE'

  WHERE ws.template_id = v_instance.template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_instance_routing(uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_instance_routing(uuid) IS
  'Mig 602: MANAGER lateral join now uses metadata->employee_id as primary source. '
  'Fixes "Direct Manager" fallback on old instances (pre-mig 583) where '
  'subject_profile_id was the admin''s profile and the step was bypassed at '
  'submission with no task created. metadata.employee_id is always accurate. '
  'Also keeps mig 601 task-assignment fallback as secondary for edge cases.';
