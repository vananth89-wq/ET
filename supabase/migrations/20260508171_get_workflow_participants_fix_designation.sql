-- =============================================================================
-- Migration 171: Fix get_workflow_participants() — remove designation fallback
--
-- ROOT CAUSE
-- ──────────
-- Migration 073 documented: employees.designation stores a picklist UUID,
-- not a human-readable label. employees.job_title is the display text.
--
-- Migration 170 introduced COALESCE(job_title, designation) for resolvedDesignation,
-- so when job_title is NULL the UUID is returned and shown in the modal bubble
-- sub-label (e.g. "53b244cd-bd50-444a-98ec-894e30c5b9e3").
--
-- FIX
-- ───
-- Use job_title only. If it's NULL, return NULL — the UI already suppresses
-- empty sub-labels gracefully (StepBubble renders nothing for null/empty string).
--
-- SPECIFIC_USER: job_title only (was: COALESCE(job_title, designation))
-- MANAGER:       job_title only, static fallback for unknown manager
-- DEPT_HEAD:     job_title only, static fallback
-- ROLE:          job_title only (was: COALESCE(job_title, designation))
--
-- All other logic unchanged from migration 170.
-- =============================================================================


DROP FUNCTION IF EXISTS get_workflow_participants(text);
DROP FUNCTION IF EXISTS get_workflow_participants(text, uuid);


CREATE OR REPLACE FUNCTION get_workflow_participants(
  p_module_code text,
  p_profile_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_id uuid;
  v_today       date := current_date;
  v_result      jsonb;
BEGIN

  -- ── 1. Find the active template assigned to this module ───────────────────
  SELECT wf_template_id
  INTO   v_template_id
  FROM   workflow_assignments
  WHERE  module_code    = p_module_code
    AND  is_active      = true
    AND  effective_from <= v_today
    AND  (effective_to IS NULL OR effective_to >= v_today)
  LIMIT  1;

  IF v_template_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  -- ── 2. Load steps, resolve approver names ─────────────────────────────────
  --
  -- NOTE: employees.designation is a picklist UUID (mig 073).
  --       Always use employees.job_title for display text.
  --
  -- approver_type values (UPPERCASE per CHECK constraint):
  --   SPECIFIC_USER | MANAGER | ROLE | DEPT_HEAD | RULE_BASED | SELF

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',           ws.step_order,
      'stepName',            ws.name,
      'approverType',        ws.approver_type,
      'approverRole',        ws.approver_role,
      'isCC',                COALESCE(ws.is_cc, false),

      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name,     'Direct Manager')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name,     'Dept. Head')
          WHEN 'ROLE'          THEN COALESCE(role_emp.name, role_row.name, ws.approver_role)
          WHEN 'RULE_BASED'    THEN COALESCE(role_row.name, ws.approver_role, ws.name)
          ELSE                      ws.name
        END,

      -- employees.designation = picklist UUID — never use it for display.
      -- Use job_title only; NULL is fine, the UI suppresses empty sub-labels.
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN profile_emp.job_title
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, 'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, 'Resolved at submission time')
          WHEN 'ROLE'          THEN role_emp.job_title
          ELSE                      NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN true
          WHEN 'ROLE'          THEN (role_emp.name IS NOT NULL)
          WHEN 'MANAGER'       THEN (mgr_emp.name  IS NOT NULL)
          WHEN 'DEPT_HEAD'     THEN (mgr_emp.name  IS NOT NULL)
          ELSE                      false
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  -- ── SPECIFIC_USER: resolve approver_profile_id → employee ─────────────────
  LEFT JOIN profiles  pr          ON pr.id          = ws.approver_profile_id
                                 AND ws.approver_type = 'SPECIFIC_USER'
  LEFT JOIN employees profile_emp ON profile_emp.id = pr.employee_id

  -- ── ROLE / RULE_BASED step 1: find the role row by code ──────────────────
  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code   = ws.approver_role
      AND  r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type IN ('ROLE', 'RULE_BASED')

  -- ── ROLE step 2: find first active holder of that role ───────────────────
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   user_roles ur
    JOIN   profiles   rp  ON rp.id  = ur.profile_id
    JOIN   employees  emp ON emp.id = rp.employee_id
    WHERE  ur.role_id   = role_row.id
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
    ORDER  BY ur.granted_at
    LIMIT  1
  ) role_emp ON ws.approver_type = 'ROLE' AND role_row.id IS NOT NULL

  -- ── MANAGER / DEPT_HEAD: resolve submitter's manager ─────────────────────
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title
    FROM   profiles  sp
    JOIN   employees se  ON se.id  = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
           AND p_profile_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
-- After applying, call the RPC and confirm resolvedDesignation is a text label
-- (e.g. "Consultant", "Senior HR Manager") and NOT a UUID.
-- SELECT get_workflow_participants('profile_personal');

-- =============================================================================
-- END OF MIGRATION 171
--
-- After applying: no type regen needed (same function signature and return shape).
-- =============================================================================
