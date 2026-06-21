-- =============================================================================
-- Migration 249: get_employee_pending_sections RPC
--
-- PROBLEM
-- ───────
-- EmployeeEditPanel queries workflow_pending_changes directly to determine
-- which sections have active change requests from the employee.
-- The wpc_select RLS policy only allows:
--   • submitted_by = auth.uid()          (the employee themselves)
--   • user_can('wf_manage', 'view')      (workflow managers)
--   • assigned approver via workflow_tasks
--
-- An HR analyst with hire_employee.view (the minimum to open the panel) but
-- without wf_manage.view gets an empty result — pendingSections stays empty
-- and all sections appear editable even when the employee has a pending
-- change request. The block silently fails.
--
-- FIX
-- ───
-- SECURITY DEFINER RPC that:
--   1. Checks caller holds hire_employee.view (minimum panel permission)
--   2. Resolves the employee's linked profile
--   3. Queries workflow_pending_changes internally (bypasses RLS)
--   4. Returns the list of module_codes with status = 'pending'
--
-- The frontend maps module_codes → section IDs and calls this RPC instead
-- of the table directly.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_pending_sections(p_employee_id uuid)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
  v_modules    text[];
BEGIN
  -- Caller must hold hire_employee.view (minimum to open EmployeeEditPanel)
  IF NOT user_can('hire_employee', 'view', NULL) THEN
    RAISE EXCEPTION 'Not authorised to view employee pending sections.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolve the auth profile linked to this employee
  SELECT id INTO v_profile_id
  FROM   profiles
  WHERE  employee_id = p_employee_id
  LIMIT  1;

  -- No linked profile → no pending changes possible
  IF v_profile_id IS NULL THEN
    RETURN ARRAY[]::text[];
  END IF;

  -- Collect all module_codes with active pending changes submitted by this employee
  SELECT ARRAY_AGG(DISTINCT module_code)
  INTO   v_modules
  FROM   workflow_pending_changes
  WHERE  submitted_by = v_profile_id
    AND  status       = 'pending';

  RETURN COALESCE(v_modules, ARRAY[]::text[]);
END;
$$;

COMMENT ON FUNCTION get_employee_pending_sections(uuid) IS
  'Returns the list of profile module_codes (e.g. profile_personal, profile_contact) '
  'that have a pending workflow_pending_changes record submitted by the employee linked '
  'to p_employee_id. Used by EmployeeEditPanel to block editing of sections under review. '
  'SECURITY DEFINER bypasses wpc_select RLS so any caller with hire_employee.view '
  'can check — not just wf_manage.view holders. Mig 249.';

REVOKE ALL   ON FUNCTION get_employee_pending_sections(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_pending_sections(uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'get_employee_pending_sections'
  ) THEN
    RAISE EXCEPTION 'ABORT: get_employee_pending_sections not found after migration.';
  END IF;
  RAISE NOTICE 'Migration 249 verified: get_employee_pending_sections present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 249
--
-- After this migration:
--   EmployeeEditPanel should call supabase.rpc('get_employee_pending_sections',
--   { p_employee_id: emp.id }) instead of querying workflow_pending_changes
--   directly. Returns string[] of module_codes.
-- =============================================================================
