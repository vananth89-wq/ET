-- =============================================================================
-- Migration 196: get_workflow_participants() — resolve SELF type to submitter name
--
-- PROBLEM
-- ───────
-- Workflow steps with approver_type = 'SELF' (typically CC / notification
-- steps that copy the submitter) fall through to ELSE in the resolvedName
-- CASE, returning ws.name (e.g. "Employee Notification" or "Employee").
-- The Submit-for-Approval modal therefore shows "Employee" as a blue chip
-- rather than the submitter's actual name, even though p_profile_id is
-- already passed to the RPC.
--
-- FIX
-- ───
-- 1. Add a self_emp LATERAL join — same pattern as the existing mgr_emp join:
--      FROM profiles sp JOIN employees emp ON emp.id = sp.employee_id
--      WHERE sp.id = p_profile_id
--    Fires only when approver_type = 'SELF' AND p_profile_id IS NOT NULL.
--
-- 2. Add WHEN 'SELF' THEN COALESCE(self_emp.name, 'You') to resolvedName.
--
-- 3. Add WHEN 'SELF' THEN COALESCE(self_emp.name, 'You') to resolvedDesignation
--    as NULL (submitter sub-label not needed in CC chips).
--
-- 4. Add WHEN 'SELF' THEN (self_emp.name IS NOT NULL) to hasResolvedPerson.
--
-- GRACEFUL DEGRADATION
-- ────────────────────
-- If p_profile_id is NULL (rare — no auth context), the lateral join produces
-- no rows and COALESCE falls back to 'You', which is still better than the
-- raw step name. All other approver types are unaffected.
--
-- NO UI CHANGES NEEDED
-- ────────────────────
-- WorkflowSubmitModal CC row already renders p.resolvedName ?? p.stepName.
-- After this migration the chip will show the submitter's real name.
--
-- Source: full function body reproduced from migration 172 + SELF additions.
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

  -- ── 2. Load steps, resolve approver / recipient names ────────────────────
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
          WHEN 'SELF'          THEN COALESCE(self_emp.name,    'You')   -- ← mig 196
          ELSE                      ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                             'Resolved at submission time')
          WHEN 'ROLE'          THEN COALESCE(role_emp.job_title, role_emp.designation_label)
          WHEN 'SELF'          THEN NULL   -- sub-label not needed for submitter CC chip
          ELSE                      NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN true
          WHEN 'ROLE'          THEN (role_emp.name IS NOT NULL)
          WHEN 'MANAGER'       THEN (mgr_emp.name  IS NOT NULL)
          WHEN 'DEPT_HEAD'     THEN (mgr_emp.name  IS NOT NULL)
          WHEN 'SELF'          THEN (self_emp.name IS NOT NULL)  -- ← mig 196
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

  -- ── SELF: submitter is the recipient — resolve to their own name ──────────
  -- (mig 196) Follows the same pattern as mgr_emp but uses the submitter's
  -- own profile row. Fires only when p_profile_id is supplied.
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles         sp
    JOIN   employees        emp ON emp.id  = sp.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'
            AND p_profile_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Function updated
SELECT proname, prosrc LIKE '%self_emp%' AS has_self_resolution
FROM   pg_proc
WHERE  proname = 'get_workflow_participants';

-- 2. Smoke test — CC chip for profile_personal should now show submitter name
--    (replace the UUID with a real profile id from your DB)
-- SELECT get_workflow_participants('profile_personal', '<your-profile-id>');

-- =============================================================================
-- END OF MIGRATION 196
--
-- After applying:
--   npx supabase db push
--   (No type regen needed — same function signature and return shape.)
-- =============================================================================
