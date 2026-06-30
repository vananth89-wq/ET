-- Migration 582: fix_hire_activation — also flip employee_employment.status
--
-- Problem: The nightly cron _sync_employment_today (00:05 UTC) syncs
-- employee_employment.status → employees.status whenever they diverge.
-- After "Fix Activation" sets employees.status = 'Active', the cron sees
-- employee_employment.status = 'Draft' and overwrites employees back to 'Draft'.
-- The employee reappears in the stuck-hire list every morning.
--
-- Fix: Also update the active employee_employment slice to status = 'Active'
-- so the cron finds no divergence and leaves the employee alone.

CREATE OR REPLACE FUNCTION fix_hire_activation(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email       text;
  v_name        text;
  v_status      text;
  v_link_ok     boolean := false;
  v_link_reason text    := '';
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
  PERFORM set_config('prowess.allow_employment_sync', 'true', true);

  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = now()
  WHERE  id = p_employee_id;

  -- ── Step 2: flip the active employment satellite slice → Active ───────────────
  -- Without this, the nightly _sync_employment_today cron sees
  -- employee_employment.status = 'Draft' and overwrites employees.status back.
  UPDATE employee_employment
  SET    status     = 'Active',
         updated_at = now()
  WHERE  employee_id  = p_employee_id
    AND  is_active    = true
    AND  effective_to = '9999-12-31'::date;

  RAISE LOG 'fix_hire_activation: employee % (%) flipped to Active (employment slice updated) by %',
            p_employee_id, v_name, auth.uid();

  -- ── Step 3: link profile if auth user exists ─────────────────────────────────
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
    'ok',             true,
    'name',           v_name,
    'profile_linked', v_link_ok,
    'profile_note',   COALESCE(v_link_reason, '')
  );
END;
$$;

REVOKE ALL     ON FUNCTION fix_hire_activation(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fix_hire_activation(uuid) TO authenticated;

COMMENT ON FUNCTION fix_hire_activation(uuid) IS
  'Admin recovery tool: flips both employees.status AND the active '
  'employee_employment slice status to Active, so the nightly '
  '_sync_employment_today cron finds no divergence and does not overwrite back. '
  'Also attempts to link the auth profile. Idempotent. '
  'Requires admin role or workflow.admin permission.';

-- ── Verification ─────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fix_hire_activation') THEN
    RAISE EXCEPTION 'ABORT: fix_hire_activation not found after migration 582.';
  END IF;
  RAISE NOTICE 'Migration 582 verified: fix_hire_activation now syncs employment satellite — OK';
END;
$$;
