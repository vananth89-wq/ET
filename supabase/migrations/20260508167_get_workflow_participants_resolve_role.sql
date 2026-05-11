-- =============================================================================
-- Migration 167: Update get_workflow_participants() — resolve role-type approvers
--
-- PROBLEM (migration 166)
-- ───────────────────────
-- For workflow_steps with approver_type = 'role', the previous version returned
-- ws.approver_role (a raw code like "hr_manager") as resolvedName, and NULL as
-- resolvedDesignation.  The UI fell back to the step name ("HR Approval") when
-- resolvedName was NULL, showing the wrong label in WorkflowSubmitModal.
--
-- SOLUTION
-- ────────
-- For 'role' steps, perform a LATERAL lookup:
--   roles  (by code)  → find the role row (id + display name)
--   user_roles         → find the first active holder of that role
--   profiles + employees → get name + job_title of that holder
--
-- If no active holder exists, fall back to roles.name (human-readable) so the
-- UI still shows something meaningful (e.g. "HR Manager") instead of a raw code.
--
-- NEW FIELD
-- ─────────
-- hasResolvedPerson (boolean) — true when a specific employee was found for a
-- role-type step.  The UI uses this to decide whether to render:
--   • initials avatar  (hasResolvedPerson = true  — show the specific person)
--   • fa-users icon    (hasResolvedPerson = false — generic "Any member" state)
--
-- All other approver types:
--   profile → hasResolvedPerson = true  (always a named person)
--   manager → hasResolvedPerson = false (resolved at submit time)
--   self    → hasResolvedPerson = false (notification only)
--
-- SECURITY POSTURE (unchanged from migration 166)
-- ────────────────
-- • SECURITY DEFINER, search_path pinned to public
-- • Scoped to one module_code per call
-- • Only name + job_title returned — same as org-chart visibility
-- • GRANT EXECUTE TO authenticated
-- =============================================================================


DROP FUNCTION IF EXISTS get_workflow_participants(text);


CREATE OR REPLACE FUNCTION get_workflow_participants(p_module_code text)
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
  -- Four approver types handled:
  --
  --   profile → LEFT JOIN profiles + employees on approver_profile_id
  --             resolvedName  = employees.name
  --             hasResolvedPerson = true
  --
  --   role    → LATERAL lookup: roles (by code) → user_roles (first active
  --             holder) → profiles → employees
  --             resolvedName  = employees.name if found, else roles.name
  --             hasResolvedPerson = (employee found)
  --
  --   manager → static label; actual manager resolved at wf_submit time
  --             hasResolvedPerson = false
  --
  --   self    → notification only; no named approver
  --             hasResolvedPerson = false

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
          WHEN 'manager' THEN 'Direct Manager'
          WHEN 'role'    THEN COALESCE(role_emp.name, role_row.name, ws.approver_role)
          ELSE                ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'profile' THEN COALESCE(profile_emp.job_title, profile_emp.designation)
          WHEN 'manager' THEN 'Resolved at submission time'
          WHEN 'role'    THEN COALESCE(role_emp.job_title, role_emp.designation)
          ELSE                NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'profile' THEN true
          WHEN 'role'    THEN (role_emp.name IS NOT NULL)
          ELSE                false
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  -- ── profile-type: resolve approver_profile_id → employee ─────────────────
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
    WHERE  ur.role_id  = role_row.id
      AND  ur.is_active = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
    ORDER  BY ur.granted_at
    LIMIT  1
  ) role_emp ON ws.approver_type = 'role' AND role_row.id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


-- Any authenticated user may call this RPC (ESS, Manager, Admin)
GRANT EXECUTE ON FUNCTION get_workflow_participants(text) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- 1. Confirm function exists and is SECURITY DEFINER
SELECT
  routine_name,
  security_type,
  routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_name   = 'get_workflow_participants'
  AND routine_schema = 'public';

-- 2. Confirm EXECUTE grant to authenticated
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name   = 'get_workflow_participants'
  AND  routine_schema = 'public';

-- 3. Smoke-test: call with a real module_code and check hasResolvedPerson appears
-- SELECT get_workflow_participants('profile_personal');

-- =============================================================================
-- END OF MIGRATION 167
--
-- After applying:
--   1. npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr > src/types/database.types.ts
--   2. The UI changes (hasResolvedPerson field) are in WorkflowSubmitModal.tsx
--      and useWorkflowParticipants.ts — no further backend changes needed.
-- =============================================================================
