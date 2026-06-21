-- =============================================================================
-- Migration 324 — Personal info gap fixes
-- =============================================================================
--
-- Gap 9/12 — wf_activate_employee: seed employee_personal on activation
--   AddEmployee.saveExtendedData now calls upsert_personal_info() during the
--   hire pipeline, so most employees already have an employee_personal row by
--   the time they are activated. However, two edge cases remain:
--     a) Employees activated without passing through the AddEmployee personal
--        section (e.g. skipped or legacy flow).
--     b) Employees created before mig 315.
--   Fix: after setting status=Active, check for an active employee_personal row.
--   If missing, INSERT one directly (SECURITY DEFINER bypasses the access guard)
--   using the current employees.name and hire_date.
--   Also: delete employee_personal_draft row if one exists (draft was written
--   by older code paths — not needed after upsert_personal_info is in place).
--
-- Gap 13 — vw_personal_name_drift: restrict to admins
--   The view was created without a REVOKE, so any authenticated user could
--   SELECT it. Revoke public access; grant only to service_role.
--   Admins check drift via the Supabase dashboard or a restricted admin RPC.
--
-- Gap 14 — drop 4-param submit_change_request overload
--   mig 046 and mig 176 registered submit_change_request(text, uuid, jsonb, text)
--   (4 params). mig 177/319 added p_comment making a 5-param version. Both
--   overloads coexist; "function is not unique" errors can surface when callers
--   omit p_comment. Drop the old 4-param signature.
-- =============================================================================


-- =============================================================================
-- 1. Gap 14 — Drop 4-param submit_change_request overload
-- =============================================================================

-- Drop old 4-param overload if it still exists (safe — the 5-param version
-- registered in mig 319 is unaffected by this DROP).
DROP FUNCTION IF EXISTS submit_change_request(text, uuid, jsonb, text);


-- =============================================================================
-- 2. Gap 13 — Restrict vw_personal_name_drift to service_role / super admins
-- =============================================================================

-- Revoke SELECT from authenticated users — this view exposes name mismatches
-- across all active employees and should be an ops-only tool.
REVOKE SELECT ON vw_personal_name_drift FROM authenticated;

-- Create a SECURITY DEFINER RPC that wraps the view, gated on super admin.
-- Admins can call it via the Supabase dashboard or a future admin UI.
CREATE OR REPLACE FUNCTION get_personal_name_drift()
RETURNS TABLE (
  employee_id          uuid,
  employee_number      text,
  employee_status      text,
  employees_name       text,
  personal_name        text,
  personal_effective_from date,
  personal_updated_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_super_admin() THEN
    RAISE EXCEPTION 'Access denied: super admin required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY SELECT * FROM vw_personal_name_drift;
END;
$$;

REVOKE ALL     ON FUNCTION get_personal_name_drift() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_personal_name_drift() TO authenticated;

COMMENT ON FUNCTION get_personal_name_drift() IS
  'Super-admin-only: returns rows from vw_personal_name_drift where '
  'employees.name diverges from the current employee_personal row. '
  'Use this to detect and remediate sync drift after job failures or '
  'direct DB writes. Mig 324.';


-- =============================================================================
-- 3. Gap 9/12 — Update wf_activate_employee to seed employee_personal
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_employee_id   text;
  v_created_by    uuid;
  v_hire_date     date;
  v_next_attempt  int;
  v_has_instance  boolean;
  v_notify_target uuid;
  v_draft         employee_personal_draft%ROWTYPE;
  v_draft_found   boolean := false;
BEGIN
  -- ── Fetch employee ────────────────────────────────────────────────────────
  SELECT status::text, business_email, name, employee_id, created_by, hire_date
  INTO   v_status, v_email, v_name, v_employee_id, v_created_by, v_hire_date
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  -- ── Re-activation guard ───────────────────────────────────────────────────
  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'wf_activate_employee: employee % is already Active — cannot re-activate.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── Step 1: Activate the employee record ──────────────────────────────────
  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 2: Seed employee_personal if no active slice exists (Gap 9) ──────
  -- Most employees already have a row from AddEmployee.saveExtendedData calling
  -- upsert_personal_info() during the hire pipeline. This guard catches:
  --   a) Employees activated without entering personal data in AddEmployee.
  --   b) Legacy employees created before mig 315.
  -- Direct INSERT here (bypassing upsert_personal_info access guard) is safe
  -- because we are already inside a SECURITY DEFINER function.
  -- The name guard trigger on employees was just armed (status → Active), but
  -- this INSERT touches employee_personal, not employees — no conflict.
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    -- Check if draft data exists (legacy path or future use)
    SELECT * INTO v_draft
    FROM   employee_personal_draft
    WHERE  employee_id = p_employee_id;
    v_draft_found := FOUND;

    IF v_draft_found THEN
        -- Seed from draft (has nationality, marital_status, gender, dob etc.)
        INSERT INTO employee_personal (
          employee_id, name, middle_name, preferred_name,
          nationality, marital_status, gender, dob, photo_url,
          effective_from, effective_to, is_active, created_by, updated_by
        ) VALUES (
          p_employee_id,
          COALESCE(v_draft.name, v_name),
          v_draft.middle_name,
          v_draft.preferred_name,
          v_draft.nationality,
          v_draft.marital_status,
          v_draft.gender,
          v_draft.dob,
          v_draft.photo_url,
          COALESCE(v_hire_date, CURRENT_DATE),
          '9999-12-31'::date,
          true,
          auth.uid(),
          auth.uid()
        );
    ELSE
      -- No draft — seed minimal row from employees.name only
      INSERT INTO employee_personal (
        employee_id, name,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id,
        v_name,
        COALESCE(v_hire_date, CURRENT_DATE),
        '9999-12-31'::date,
        true,
        auth.uid(),
        auth.uid()
      );
    END IF;
  END IF;

  -- ── Step 3: Clean up employee_personal_draft (Gap 12) ────────────────────
  -- Delete draft row if it exists. After mig 315, AddEmployee writes directly
  -- to employee_personal via upsert_personal_info, so the draft is no longer
  -- populated. This DELETE is a belt-and-suspenders cleanup for any legacy
  -- draft rows that may have been created by older code paths.
  DELETE FROM employee_personal_draft WHERE employee_id = p_employee_id;

  -- ── Step 4: Record invite attempt ─────────────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  -- ── Step 5: Stamp invite_sent_at ─────────────────────────────────────────
  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 6: Engine-path vs. direct-path detection ─────────────────────────
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
      RAISE EXCEPTION
        'A workflow approval process is configured for New Hire. '
        'Please use "Submit for Approval" instead of activating directly. '
        'Direct activation is only available when no workflow is configured.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_notify_target := COALESCE(v_created_by, auth.uid());

    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_notify_target,
      'Employee activated: ' || v_name,
      v_name || ' (' || COALESCE(v_employee_id, '—') || ') has been directly '
        || 'activated (no approval workflow configured). '
        || 'The invite record has been created.',
      '/employees'
    );
  END IF;

  -- NOTE: Auth OTP (signInWithOtp) and link_profile_to_employee must be
  -- called from the frontend after this RPC returns.
END;
$$;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-approved employee: sets status=Active, locked=false, '
  'seeds employee_personal if no active slice exists (Gap 9 fix, mig 324), '
  'cleans up employee_personal_draft (Gap 12, mig 324), records invite. '
  'Mig 252: guard blocks direct-activate when workflow is configured. '
  'Mig 253: direct-activate notification targets employees.created_by. '
  'Mig 324: personal info seeding + draft cleanup added. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL    ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;
