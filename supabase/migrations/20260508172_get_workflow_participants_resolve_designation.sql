-- =============================================================================
-- Migration 172: get_workflow_participants() — resolve designation via picklist
--
-- CONTEXT
-- ───────
-- employees.designation stores a picklist_values.id UUID (confirmed mig 073).
-- employees.job_title is a plain text field that is often NULL.
--
-- Migration 171 switched to job_title-only, which caused blank sub-labels for
-- employees who have designation set but no job_title (e.g. Safia Shahanaz
-- shows "Consultant" in the employee list, but that comes from the picklist
-- resolution of employees.designation, not from job_title).
--
-- FIX
-- ───
-- Inside each employee-resolving LATERAL, add:
--   LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
-- and select pv.value as designation_label.
--
-- resolvedDesignation priority (per approver type):
--   SPECIFIC_USER  → job_title ?? designation_label
--   MANAGER        → job_title ?? designation_label ?? 'Resolved at submission time'
--   DEPT_HEAD      → job_title ?? designation_label ?? 'Resolved at submission time'
--   ROLE           → job_title ?? designation_label
--
-- This matches how the rest of the app displays employee designations.
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

      -- Prefer job_title; fall back to picklist-resolved designation label.
      -- employees.designation is a picklist_values UUID (mig 073) — resolved
      -- via the pv alias inside each LATERAL.
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE'          THEN COALESCE(role_emp.job_title, role_emp.designation_label)
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

  -- ── SPECIFIC_USER: named profile → employee + picklist designation ────────
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles         pr
    JOIN   employees        emp ON emp.id  = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  -- ── ROLE / RULE_BASED step 1: find the role row by code ──────────────────
  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code   = ws.approver_role
      AND  r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type IN ('ROLE', 'RULE_BASED')

  -- ── ROLE step 2: find first active holder + picklist designation ──────────
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   user_roles       ur
    JOIN   profiles         rp  ON rp.id  = ur.profile_id
    JOIN   employees        emp ON emp.id = rp.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  ur.role_id   = role_row.id
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
    ORDER  BY ur.granted_at
    LIMIT  1
  ) role_emp ON ws.approver_type = 'ROLE' AND role_row.id IS NOT NULL

  -- ── MANAGER / DEPT_HEAD: submitter's manager + picklist designation ───────
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles         sp
    JOIN   employees        se  ON se.id  = sp.employee_id
    JOIN   employees        mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id  = mgr.designation::uuid
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
-- SELECT get_workflow_participants('profile_personal');
-- resolvedDesignation for Safia Shahanaz should now show "Consultant"
-- (from picklist_values.value where id = employees.designation UUID).

-- =============================================================================
-- END OF MIGRATION 172
--
-- After applying: no type regen needed (same signature and return shape).
-- =============================================================================
