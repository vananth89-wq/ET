-- =============================================================================
-- Migration 166: SECURITY DEFINER RPC — get_workflow_participants
--
-- PROBLEM
-- ───────
-- Migration 153 tightened workflow_steps SELECT to:
--   user_can('wf_templates', 'view', NULL)
-- ESS users do not have wf_templates.view, so direct client queries on
-- workflow_steps return an empty array silently — causing the
-- WorkflowSubmitModal to show "No approvers" even when a template exists.
--
-- The same gap exists for profiles and employees: ESS users can only read
-- their own rows (auth.uid() = id / own employee_id), not the approver's.
--
-- SOLUTION
-- ────────
-- A SECURITY DEFINER function that:
--   1. Finds the active workflow_assignments row for the given module_code
--   2. Reads workflow_steps for that template (bypasses RLS as definer)
--   3. LEFT JOINs profiles + employees for profile-type steps (bypasses RLS)
--   4. Returns a jsonb array of resolved participant objects
--
-- ESS users call the RPC — the function reads the four tables on their
-- behalf and returns only display-safe data (name, job_title, routing order).
-- No PII is exposed. Equivalent to SF/Workday routing-preview services.
--
-- TABLES READ INTERNALLY (as definer, bypassing RLS)
-- ────────────────────────────────────────────────────
--   workflow_assignments  — find active template (already open SELECT anyway)
--   workflow_steps        — blocked for ESS directly; safe via definer
--   profiles              — ESS can only read own; approver's profile needed
--   employees             — ESS can only read own; approver's name/title needed
--
-- DATA RETURNED (per step)
-- ────────────────────────
--   stepOrder            — integer
--   stepName             — template-defined label
--   approverType         — 'profile' | 'manager' | 'role' | 'self'
--   approverRole         — role code string or null
--   isCC                 — boolean
--   resolvedName         — display name (person name / 'Direct Manager' / role)
--   resolvedDesignation  — job_title for profile-type; note for manager-type
--
-- SECURITY POSTURE
-- ────────────────
-- • Scoped to one module_code per call — no bulk template data exposed
-- • Only name + job_title returned for approvers (same as org chart visibility)
-- • GRANT EXECUTE TO authenticated — any logged-in user may call it
-- • search_path pinned to public to prevent search-path hijack attacks
-- =============================================================================


-- Drop previous version if exists (idempotent)
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
  WHERE  module_code   = p_module_code
    AND  is_active     = true
    AND  effective_from <= v_today
    AND  (effective_to IS NULL OR effective_to >= v_today)
  LIMIT  1;

  IF v_template_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  -- ── 2. Load steps, resolve approver names in one query ───────────────────
  -- profile-type: JOIN profiles → employees to get name + job_title
  -- manager-type: static label (actual manager resolved at wf_submit time)
  -- role-type:    return the role code as resolvedName (prettified in UI)
  -- self-type:    notification only, no named approver
  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',           ws.step_order,
      'stepName',            ws.name,
      'approverType',        ws.approver_type,
      'approverRole',        ws.approver_role,
      'isCC',                COALESCE(ws.is_cc, false),
      'resolvedName',
        CASE ws.approver_type
          WHEN 'profile' THEN COALESCE(emp.name, 'Unknown')
          WHEN 'manager' THEN 'Direct Manager'
          WHEN 'role'    THEN ws.approver_role
          ELSE                ws.name
        END,
      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'profile' THEN COALESCE(emp.job_title, emp.designation)
          WHEN 'manager' THEN 'Resolved at submission time'
          ELSE                NULL
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws
  LEFT  JOIN profiles  pr  ON pr.id  = ws.approver_profile_id
                          AND ws.approver_type = 'profile'
  LEFT  JOIN employees emp ON emp.id = pr.employee_id
  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


-- Any authenticated user may call this RPC (ESS, Manager, Admin)
GRANT EXECUTE ON FUNCTION get_workflow_participants(text) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

-- Confirm function exists and is SECURITY DEFINER
SELECT
  routine_name,
  security_type,
  routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_name   = 'get_workflow_participants'
  AND routine_schema = 'public';

-- Confirm EXECUTE grant to authenticated
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name   = 'get_workflow_participants'
  AND  routine_schema = 'public';

-- =============================================================================
-- END OF MIGRATION 166
--
-- After applying:
--   1. Run: npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr > src/types/database.types.ts
--   2. Update useWorkflowParticipants.ts to call .rpc('get_workflow_participants', ...)
--      instead of the current 3-step direct table query chain
-- =============================================================================
