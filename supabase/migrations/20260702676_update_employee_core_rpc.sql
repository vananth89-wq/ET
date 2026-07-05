-- =============================================================================
-- Migration 676 — update_employee_core RPC
--
-- SECURITY DEFINER function for admins to update the core, non-satellite
-- fields on the employees table: status, role, locked.
--
-- status IS a mirror column guarded by fn_guard_employee_employment_sync,
-- so this RPC sets the bypass flag before writing. role and locked are
-- not mirror columns and can be written without the flag.
-- =============================================================================

CREATE OR REPLACE FUNCTION update_employee_core(
  p_employee_id  uuid,
  p_status       text    DEFAULT NULL,
  p_role         text    DEFAULT NULL,
  p_locked       boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_patch jsonb := '{}'::jsonb;
BEGIN
  -- ── 1. Permission ──────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('hire_employee.edit')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied.');
  END IF;

  -- ── 2. Validate ───────────────────────────────────────────────────────────
  IF p_status IS NOT NULL AND p_status NOT IN (
    'Draft', 'Incomplete', 'Pending', 'Active', 'Inactive', 'Rejected'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Invalid status "%s".', p_status));
  END IF;

  IF p_role IS NOT NULL AND p_role NOT IN (
    'Employee', 'Manager', 'Department Manager'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Invalid role "%s".', p_role));
  END IF;

  -- ── 3. Set bypass so the guard trigger passes mirror-column writes ─────────
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  -- ── 4. Build and run the update ──────────────────────────────────────────
  UPDATE employees
  SET
    status  = COALESCE(p_status,  status),
    role    = COALESCE(p_role,    role),
    locked  = COALESCE(p_locked,  locked),
    updated_at = now()
  WHERE id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Employee not found.');
  END IF;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION update_employee_core(uuid, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION update_employee_core IS
  'Mig 676: admin RPC to update non-satellite employees fields (status, role, locked). '
  'Sets allow_employment_sync bypass flag to pass the mirror-column guard trigger.';
