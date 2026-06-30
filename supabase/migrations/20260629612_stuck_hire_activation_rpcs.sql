-- =============================================================================
-- Migration 576 — Stuck hire activation: detection + fix RPCs
--
-- get_stuck_hire_activations()
--   Returns employees whose hire workflow is approved but status != Active.
--   Used by Workflow Operations banner and Employee Details list.
--
-- fix_hire_activation(p_employee_id uuid)
--   Flips employees.status → Active, links auth profile, grants ESS role.
--   Safe to call repeatedly (idempotent).
-- =============================================================================

-- ── 1. get_stuck_hire_activations ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_stuck_hire_activations()
RETURNS TABLE (
  employee_id    uuid,
  employee_ref   text,
  name           text,
  business_email text,
  department     text,
  job_title      text,
  approved_at    timestamptz,
  instance_id    uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    e.id                                                        AS employee_id,
    e.employee_id                                               AS employee_ref,
    e.name,
    e.business_email,
    d.name                                                      AS department,
    e.job_title,
    wi.completed_at                                             AS approved_at,
    wi.id                                                       AS instance_id
  FROM   workflow_instances wi
  JOIN   employees          e  ON e.id = wi.record_id
  LEFT   JOIN departments   d  ON d.id = e.dept_id
  WHERE  wi.module_code = 'employee_hire'
    AND  wi.status      = 'approved'
    AND  e.status      != 'Active'
    AND  e.deleted_at  IS NULL
  ORDER  BY wi.completed_at DESC;
$$;

REVOKE ALL    ON FUNCTION get_stuck_hire_activations() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_stuck_hire_activations() TO authenticated;

COMMENT ON FUNCTION get_stuck_hire_activations() IS
  'Returns employees whose hire workflow completed (approved) but status is not Active. '
  'Used by WorkflowOperations alert banner and EmployeeDetails amber row highlight.';


-- ── 2. fix_hire_activation ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fix_hire_activation(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email      text;
  v_name       text;
  v_status     text;
  v_link_ok    boolean := false;
  v_link_reason text   := '';
BEGIN
  -- ── Permission check ────────────────────────────────────────────────────────
  IF NOT (has_role('admin') OR has_permission('workflow.admin')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient permissions');
  END IF;

  -- ── Load employee ────────────────────────────────────────────────────────────
  SELECT status::text, business_email, name
  INTO   v_status, v_email, v_name
  FROM   employees
  WHERE  id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'employee not found');
  END IF;

  IF v_status = 'Active' THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'already Active — no action needed');
  END IF;

  -- ── Step 1: flip employees.status → Active ───────────────────────────────────
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = now()
  WHERE  id = p_employee_id;

  RAISE LOG 'fix_hire_activation: employee % (%) flipped to Active by %',
            p_employee_id, v_name, auth.uid();

  -- ── Step 2: link profile if auth user exists ─────────────────────────────────
  IF v_email IS NOT NULL THEN
    DECLARE
      v_link jsonb;
    BEGIN
      SELECT link_profile_to_employee(v_email) INTO v_link;
      v_link_ok     := (v_link->>'ok')::boolean;
      v_link_reason := v_link->>'reason';
    EXCEPTION WHEN OTHERS THEN
      v_link_ok     := false;
      v_link_reason := SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'name',        v_name,
    'profile_linked', v_link_ok,
    'profile_note',   COALESCE(v_link_reason, '')
  );
END;
$$;

REVOKE ALL     ON FUNCTION fix_hire_activation(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fix_hire_activation(uuid) TO authenticated;

COMMENT ON FUNCTION fix_hire_activation(uuid) IS
  'Admin recovery tool: flips employees.status to Active and attempts to link the '
  'auth profile. Idempotent — safe to call on already-Active employees. '
  'Requires admin role or workflow.admin permission.';


-- ── Verification ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_stuck_hire_activations') THEN
    RAISE EXCEPTION 'ABORT: get_stuck_hire_activations not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fix_hire_activation') THEN
    RAISE EXCEPTION 'ABORT: fix_hire_activation not found.';
  END IF;
  RAISE NOTICE 'Migration 576 verified: get_stuck_hire_activations + fix_hire_activation present.';
END $$;
