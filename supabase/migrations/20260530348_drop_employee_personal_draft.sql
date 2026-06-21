-- =============================================================================
-- Migration 348 — Drop employee_personal_draft (dead table)
-- =============================================================================
--
-- HISTORY
-- ───────
-- Mig 316 created employee_personal_draft as a staging table for the hire
-- pipeline (Draft/Incomplete/Pending employees), intending for personal info
-- to live there until activation, then be promoted to employee_personal.
--
-- Mig 317 (same day, May 29) superseded this design by extending
-- upsert_personal_info to allow writes directly to employee_personal for
-- pre-activation employees. The draft table was never populated in production.
--
-- Mig 324 explicitly noted: "After mig 315, AddEmployee writes directly to
-- employee_personal via upsert_personal_info, so the draft is no longer needed."
--
-- SCOPE
-- ─────
-- 1. Replace wf_activate_employee — remove all draft table references
--    (v_draft variable, SELECT, draft-based INSERT branch, DELETE)
-- 2. Drop employee_personal_draft (CASCADE drops trigger + RLS policies)
-- =============================================================================


-- =============================================================================
-- 1. Replace wf_activate_employee — strip draft table references
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
  v_first_name    text;
  v_last_name     text;
  v_computed_name text;
BEGIN
  SELECT status::text, business_email, name, employee_id, created_by, hire_date
  INTO   v_status, v_email, v_name, v_employee_id, v_created_by, v_hire_date
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'wf_activate_employee: employee % is already Active — cannot re-activate.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Seed employee_personal if not already present.
  -- Since mig 317, AddEmployee writes directly to employee_personal via
  -- upsert_personal_info during the hire pipeline, so this row almost always
  -- exists by activation time. Fallback handles legacy / skipped-section cases.
  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    v_first_name := CASE
      WHEN position(' ' IN v_name) > 0
        THEN left(v_name, length(v_name) - length(split_part(v_name, ' ', -1)) - 1)
      ELSE COALESCE(v_name, 'Unknown')
    END;
    v_last_name := CASE
      WHEN position(' ' IN v_name) > 0
        THEN split_part(v_name, ' ', -1)
      ELSE NULL
    END;
    v_computed_name := compute_full_name(v_first_name, NULL, v_last_name);

    INSERT INTO employee_personal (
      employee_id, name, first_name, last_name,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id,
      v_computed_name,
      v_first_name,
      v_last_name,
      COALESCE(v_hire_date, CURRENT_DATE),
      '9999-12-31'::date,
      true,
      auth.uid(),
      auth.uid()
    );
  END IF;

  -- Record invite
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

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
      'Employee activated: ' || COALESCE(v_computed_name, v_name),
      COALESCE(v_computed_name, v_name) || ' (' || COALESCE(v_employee_id, '—')
        || ') has been directly activated (no approval workflow configured). '
        || 'The invite record has been created.',
      '/employees'
    );
  END IF;
END;
$$;

REVOKE ALL    ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-approved employee. '
  'Mig 348: removed all employee_personal_draft references (table dropped). '
  'employee_personal row is almost always present by activation time (written '
  'by upsert_personal_info during the hire pipeline since mig 317). Fallback '
  'seeds from employees.name for legacy / skipped-section cases. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';


-- =============================================================================
-- 2. Drop employee_personal_draft
--    CASCADE drops: trigger employee_personal_draft_updated_at
--                   RLS policies epd_select / epd_insert / epd_update / epd_delete
-- =============================================================================

DROP TABLE IF EXISTS employee_personal_draft CASCADE;
