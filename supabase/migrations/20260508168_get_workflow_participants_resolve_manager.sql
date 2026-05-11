-- =============================================================================
-- Migration 168: get_workflow_participants() — resolve manager-type approver
--
-- PROBLEM (migration 167)
-- ───────────────────────
-- For workflow_steps with approver_type = 'manager', the function returned the
-- static label 'Direct Manager' because it had no way to know WHOSE manager
-- to look up — the submitting employee was not part of the function signature.
--
-- SOLUTION
-- ────────
-- Add an optional second parameter p_profile_id (uuid, DEFAULT NULL).
-- When supplied, a LATERAL join resolves the submitter's direct manager:
--
--   profiles (p_profile_id) → employee (employee_id)
--     → employees.manager_id → manager's employees row
--
-- employees.manager_id is a self-referencing FK (employees_manager_id_fkey)
-- confirmed in database.types.ts.
--
-- When p_profile_id is NULL (backward-compatible call), the function behaves
-- exactly as migration 167 — manager-type steps still return 'Direct Manager'.
--
-- CALLER SOURCES
-- ──────────────
-- The profile UUID is available in the React app via useAuth() → profile?.id
-- (auth.uid() === profiles.id). No extra fetch is needed — it is already loaded
-- in AuthContext when the user is signed in.
--
-- UPDATED FIELDS FOR MANAGER-TYPE STEPS
-- ──────────────────────────────────────
--   resolvedName        → manager's employees.name  (if found)
--                         'Direct Manager'           (if p_profile_id null / no manager set)
--   resolvedDesignation → manager's employees.job_title / designation (if found)
--                         'Resolved at submission time'                (fallback)
--   hasResolvedPerson   → true if manager was resolved, false otherwise
--
-- All other approver types are unchanged from migration 167.
--
-- SECURITY POSTURE (unchanged)
-- ─────────────────────────────
-- • SECURITY DEFINER, search_path = public
-- • Only name + job_title returned for manager (same as org-chart visibility)
-- • GRANT EXECUTE TO authenticated
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

  -- ── 2. Load steps, resolve all approver types ─────────────────────────────
  --
  -- approver_type resolution matrix:
  --
  --   profile → LEFT JOIN profiles + employees on approver_profile_id
  --             resolvedName        = employees.name
  --             resolvedDesignation = employees.job_title / designation
  --             hasResolvedPerson   = true
  --
  --   role    → LATERAL: roles (by code) → first active user_roles holder
  --             → profiles → employees
  --             resolvedName        = employee name if found, else roles.name
  --             resolvedDesignation = job_title if found, else NULL
  --             hasResolvedPerson   = (employee found)
  --
  --   manager → LATERAL: p_profile_id → profiles → employees (submitter)
  --             → employees.manager_id → manager's employees row
  --             resolvedName        = manager name if p_profile_id supplied
  --             resolvedDesignation = manager's job_title / designation
  --             hasResolvedPerson   = (manager found)
  --             Falls back to 'Direct Manager' / 'Resolved at submission time'
  --             when p_profile_id IS NULL (backward-compatible).
  --
  --   self    → notification only; no named approver
  --             hasResolvedPerson   = false

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',           ws.step_order,
      'stepName',            ws.name,
      'approverType',        ws.approver_type,
      'approverRole',        ws.approver_role,
      'isCC',                COALESCE(ws.is_cc, false),

      'resolvedName',
        CASE ws.approver_type
          WHEN 'profile' THEN COALESCE(profile_emp.name,  'Unknown')
          WHEN 'role'    THEN COALESCE(role_emp.name, role_row.name, ws.approver_role)
          WHEN 'manager' THEN COALESCE(mgr_emp.name,  'Direct Manager')
          ELSE                ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'profile' THEN COALESCE(profile_emp.job_title, profile_emp.designation)
          WHEN 'role'    THEN COALESCE(role_emp.job_title,    role_emp.designation)
          WHEN 'manager' THEN COALESCE(mgr_emp.job_title,     mgr_emp.designation,
                                       'Resolved at submission time')
          ELSE                NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'profile' THEN true
          WHEN 'role'    THEN (role_emp.name IS NOT NULL)
          WHEN 'manager' THEN (mgr_emp.name  IS NOT NULL)
          ELSE                false
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  -- ── profile-type: approver_profile_id → profiles → employees ─────────────
  LEFT JOIN profiles  pr          ON pr.id          = ws.approver_profile_id
                                 AND ws.approver_type = 'profile'
  LEFT JOIN employees profile_emp ON profile_emp.id = pr.employee_id

  -- ── role-type step 1: find the role row by code ───────────────────────────
  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code   = ws.approver_role
      AND  r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type = 'role'

  -- ── role-type step 2: find first active holder of that role ──────────────
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, emp.designation
    FROM   user_roles ur
    JOIN   profiles   rp  ON rp.id  = ur.profile_id
    JOIN   employees  emp ON emp.id = rp.employee_id
    WHERE  ur.role_id   = role_row.id
      AND  ur.is_active = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
    ORDER  BY ur.granted_at
    LIMIT  1
  ) role_emp ON ws.approver_type = 'role' AND role_row.id IS NOT NULL

  -- ── manager-type: p_profile_id → submitter employee → manager employee ───
  -- Two-hop self-join on employees using employees.manager_id (self-ref FK).
  -- Only fires when p_profile_id is supplied; gracefully returns NULL otherwise.
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, mgr.designation
    FROM   profiles  sp              -- submitter's profile row
    JOIN   employees se  ON se.id  = sp.employee_id   -- submitter's employee
    JOIN   employees mgr ON mgr.id = se.manager_id    -- manager's employee
    WHERE  sp.id = p_profile_id      -- NULL-safe: evaluates false when NULL
    LIMIT  1
  ) mgr_emp ON ws.approver_type = 'manager' AND p_profile_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


-- Any authenticated user may call this RPC (ESS, Manager, Admin)
GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm both overloads are gone and only the new signature exists
SELECT routine_name, security_type,
       pg_get_function_arguments(p.oid) AS args
FROM   information_schema.routines r
JOIN   pg_proc p ON p.proname = r.routine_name
WHERE  r.routine_name   = 'get_workflow_participants'
  AND  r.routine_schema = 'public';

-- 2. Confirm EXECUTE grant
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name   = 'get_workflow_participants'
  AND  routine_schema = 'public';

-- 3. Smoke-test without profile_id (backward-compatible — manager = 'Direct Manager')
-- SELECT get_workflow_participants('expense_reports');

-- 4. Smoke-test with profile_id (should resolve actual manager name)
-- SELECT get_workflow_participants('expense_reports', '<your-profile-uuid>');

-- =============================================================================
-- END OF MIGRATION 168
--
-- After applying:
--   1. npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr > src/types/database.types.ts
--   2. Update useWorkflowParticipants.ts — accept profileId param, pass as p_profile_id
--   3. Update WorkflowSubmitModal.tsx   — call useAuth() → profile?.id, pass to hook
-- =============================================================================
