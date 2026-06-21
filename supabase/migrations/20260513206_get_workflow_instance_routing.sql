-- =============================================================================
-- Migration 206: get_workflow_instance_routing()
--
-- PURPOSE
-- ───────
-- Approvers need to see the full routing chain for an in-flight instance —
-- not the hypothetical template-level preview (get_workflow_participants) but
-- the live per-step status: who has already approved, who is current, who is
-- still pending.
--
-- Triggered from a "View participants" link in the approver task detail panel.
--
-- FUNCTION
-- ────────
-- get_workflow_instance_routing(p_instance_id uuid) → jsonb
--
-- Returns a JSONB array (one element per active workflow_steps row) with:
--
--   stepOrder          int
--   stepName           text
--   approverType       text    ROLE | MANAGER | DEPT_HEAD | SPECIFIC_USER | SELF
--   approverRole       text?
--   isCC               bool
--   approvalMode       text?   'ALL_OF' | null
--   status             text    'completed' | 'active' | 'pending'
--   resolvedName       text    display name for the approver slot
--   resolvedDesignation text?
--   roleMembers        jsonb?  [{name, jobTitle}] for ROLE steps (mig 205 pattern)
--   approvedByName     text?   actor who last approved this step (completed steps only)
--   approvedAt         timestamptz? timestamp of that approval
--
-- SECURITY
-- ────────
-- SECURITY DEFINER — bypasses RLS on workflow_steps, profiles, employees.
-- Guard: caller must be the instance submitter OR have had any task on the instance.
-- This means both the employee (submitter) and any approver (past or present) can call it.
--
-- DESIGN NOTES
-- ────────────
-- • step status is derived from current_step alone (no action_log join needed):
--     completed  → step_order < current_step
--                  (also all steps when instance.status = 'approved')
--     active     → step_order = current_step AND status IN ('in_progress','awaiting_clarification')
--     pending    → all others
-- • approvedByName / approvedAt: most recent 'approved' action_log entry for that step.
--   Correct after sendback+resubmit cycles (most recent = most relevant).
-- • resolvedName / roleMembers: same lateral-join pattern as get_workflow_participants (mig 205).
-- =============================================================================

DROP FUNCTION IF EXISTS get_workflow_instance_routing(uuid);

CREATE FUNCTION get_workflow_instance_routing(
  p_instance_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  uuid := auth.uid();
  v_instance   record;
  v_result     jsonb;
BEGIN
  -- ── Load instance ──────────────────────────────────────────────────────────
  SELECT wi.id, wi.template_id, wi.current_step, wi.status, wi.submitted_by
  INTO   v_instance
  FROM   workflow_instances wi
  WHERE  wi.id = p_instance_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'get_workflow_instance_routing: instance % not found', p_instance_id;
  END IF;

  -- ── Security guard ─────────────────────────────────────────────────────────
  -- Allow: submitter OR any past/present task holder for this instance.
  IF v_instance.submitted_by IS DISTINCT FROM v_caller_id THEN
    IF NOT EXISTS (
      SELECT 1 FROM workflow_tasks
      WHERE  instance_id = p_instance_id
        AND  assigned_to = v_caller_id
    ) THEN
      RAISE EXCEPTION 'get_workflow_instance_routing: access denied';
    END IF;
  END IF;

  -- ── Build step list ────────────────────────────────────────────────────────
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

      -- ── Who approved this step (most recent, for completed steps) ─────────
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

      -- ── Resolved display name (mirrors get_workflow_participants mig 205) ──
      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name, 'Dept. Head')
          WHEN 'ROLE'          THEN COALESCE(role_row.name, ws.approver_role)
          WHEN 'SELF'          THEN COALESCE(self_emp.name, 'You')
          ELSE                      ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE'          THEN
            CASE WHEN ws.approval_mode = 'ALL_OF'
                 THEN 'All active members must approve'
                 ELSE 'All active members — first to approve wins'
            END
          WHEN 'SELF'          THEN NULL
          ELSE                      NULL
        END,

      -- ── roleMembers: same as mig 205, active role holders for ROLE steps ──
      'roleMembers',
        CASE ws.approver_type
          WHEN 'ROLE' THEN (
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
          ELSE NULL::jsonb
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  -- Resolve SPECIFIC_USER name + designation
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles    pr
    JOIN   employees   emp ON emp.id = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  -- Resolve role display name
  LEFT JOIN LATERAL (
    SELECT r.name
    FROM   roles r
    WHERE  r.code = ws.approver_role AND r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type = 'ROLE'

  -- Resolve MANAGER / DEPT_HEAD via the submitter's employee record
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles  sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  sp.id = v_instance.submitted_by
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')

  -- Resolve SELF via the submitter
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
  'Returns the live routing chain for an in-flight workflow instance. '
  'Status per step: completed (step_order < current_step), active (= current_step, in_progress), pending. '
  'approvedByName / approvedAt: most recent approved action from action_log. '
  'roleMembers: active role holders for ROLE steps (same as get_workflow_participants mig 205). '
  'Security: caller must be the submitter or any past/present task holder on the instance.';

-- =============================================================================
-- END OF MIGRATION 206
-- =============================================================================
