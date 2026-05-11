-- =============================================================================
-- Migration 170: Fix get_workflow_participants() — approver_type casing bug
--
-- ROOT CAUSE
-- ──────────
-- Migrations 166–168 used lowercase strings in the CASE statement:
--   WHEN 'profile' | 'manager' | 'role' | 'self'
--
-- But workflow_steps.approver_type stores UPPERCASE values enforced by CHECK:
--   'SPECIFIC_USER' | 'MANAGER' | 'ROLE' | 'DEPT_HEAD' | 'RULE_BASED' | 'SELF'
-- (confirmed in migrations 030 and 056)
--
-- Consequence: every step fell through to ELSE ws.name, returning the step
-- name ("HR Approval") as resolvedName for ALL non-SPECIFIC_USER types.
-- hasResolvedPerson was also always false (or true by accident for profile).
-- The UI checks participant.approverType === 'role' also never matched.
--
-- FIX
-- ───
-- Recreate the function with the correct UPPERCASE WHEN clauses:
--   'SPECIFIC_USER' (was 'profile')
--   'MANAGER'       (was 'manager')
--   'ROLE'          (was 'role')
--   'DEPT_HEAD'     new — resolved at submission, same as MANAGER treatment
--   'RULE_BASED'    new — like ROLE but without a named holder
--   'SELF'          (was 'self')
--
-- DEPT_HEAD and RULE_BASED were not in migrations 166–168 at all; they also
-- fell through to ELSE ws.name, which was wrong.
--
-- NO OTHER LOGIC CHANGES — all joins, laterals, and security posture unchanged.
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
  -- approver_type values (all UPPERCASE per CHECK constraint, mig 030 + 056):
  --
  --   SPECIFIC_USER → named profile; JOIN profiles + employees
  --   ROLE          → any holder of approver_role; LATERAL lookup
  --   MANAGER       → submitter's line manager; LATERAL from p_profile_id
  --   DEPT_HEAD     → department head; same treatment as MANAGER (resolved at submit)
  --   RULE_BASED    → rule-evaluated; show role-like (no named person until submit)
  --   SELF          → notification only; no named approver

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

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation)
          WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation,
                                             'Resolved at submission time')
          WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation,
                                             'Resolved at submission time')
          WHEN 'ROLE'          THEN COALESCE(role_emp.job_title, role_emp.designation)
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
    SELECT emp.name, emp.job_title, emp.designation
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
    SELECT mgr.name, mgr.job_title, mgr.designation
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


-- Any authenticated user may call this RPC (ESS, Manager, Admin)
GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm the corrected function exists
SELECT routine_name, security_type
FROM   information_schema.routines
WHERE  routine_name   = 'get_workflow_participants'
  AND  routine_schema = 'public';

-- 2. Smoke-test (replace module code as appropriate):
-- SELECT get_workflow_participants('profile_personal');
-- Expected: resolvedName should be a person's name (not step name) for
--           SPECIFIC_USER steps, and role/manager labels for others.

-- =============================================================================
-- END OF MIGRATION 170
--
-- After applying:
--   1. npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr
--      > src/types/database.types.ts
--   2. UI fix: WorkflowSubmitModal.tsx — update 'role'/'manager' checks to
--      'ROLE'/'MANAGER' (see companion UI change)
-- =============================================================================
