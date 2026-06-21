-- Migration 262: Fix get_hire_submission_mode() call signature in submit_hire
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM
-- ───────
-- submit_hire (as last rewritten in mig 261) calls:
--
--     v_mode := get_hire_submission_mode(p_employee_id);
--
-- get_hire_submission_mode was defined in mig 252 with ZERO parameters:
--
--     CREATE OR REPLACE FUNCTION get_hire_submission_mode()
--
-- PostgreSQL resolves function calls by exact signature. There is no overload
-- get_hire_submission_mode(uuid), so the call raises:
--
--     ERROR 42883: function get_hire_submission_mode(uuid) does not exist
--
-- This error fires on every Submit for Approval click, completely blocking the
-- hire pipeline.
--
-- ROOT CAUSE
-- ──────────
-- get_hire_submission_mode() determines the submission mode from the calling
-- user's workflow assignment (via resolve_workflow_for_submission) — not from
-- the employee record. The employee UUID is irrelevant to this lookup.
-- Migs 254, 260, and 261 all incorrectly passed p_employee_id as an argument
-- when copying the submit_hire template; mig 252's zero-arg definition was
-- always correct.
--
-- FIX
-- ───
-- Rewrite submit_hire replacing the one incorrect call with the correct
-- zero-arg call. All other logic is identical to mig 261.
-- ─────────────────────────────────────────────────────────────────────────────


CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_emp            employees%ROWTYPE;
  v_created_by     uuid;
  v_wf_template_id uuid;
  v_template_code  text;
  v_instance_id    uuid;
  v_mode           text;
BEGIN
  -- ── 1. Load employee record ───────────────────────────────────────────────
  SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee record not found.' USING ERRCODE = 'no_data_found';
  END IF;

  -- ── 2. Status gate ────────────────────────────────────────────────────────
  IF v_emp.status NOT IN ('Draft', 'Incomplete') THEN
    RAISE EXCEPTION
      'Only Draft or Incomplete hire records can be submitted (current status: %).',
      v_emp.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ── 3. Ownership check ────────────────────────────────────────────────────
  -- Allow: creator, HR Head (edit_all_pending), super admin.
  -- Legacy records (created_by IS NULL, pre-mig 253): anyone may submit.
  v_created_by := v_emp.created_by;
  IF v_created_by IS NOT NULL
    AND v_created_by != auth.uid()
    AND NOT user_can('hire_employee', 'edit_all_pending', NULL)
    AND NOT is_super_admin()
  THEN
    RAISE EXCEPTION
      'Only the HR Analyst who created this hire record may submit it for approval. '
      'If you need to submit on their behalf, ask an HR Head or administrator.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── 4. Required-field validation ─────────────────────────────────────────
  PERFORM validate_hire_fields(p_employee_id);

  -- ── 5. Resolve submission mode ────────────────────────────────────────────
  -- get_hire_submission_mode() takes NO arguments — it resolves the mode from
  -- the calling user's workflow assignment via resolve_workflow_for_submission.
  -- Passing p_employee_id was a bug introduced in mig 254 and carried forward.
  v_mode := get_hire_submission_mode();

  -- ── 5a. WORKFLOW mode ─────────────────────────────────────────────────────
  IF v_mode = 'workflow' THEN

    v_wf_template_id := resolve_workflow_for_submission('employee_hire', auth.uid());
    IF v_wf_template_id IS NULL THEN
      RAISE EXCEPTION
        'No active workflow template found for employee_hire. '
        'Please configure one in Workflow Templates before submitting.'
        USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    SELECT code INTO v_template_code
    FROM   workflow_templates
    WHERE  id = v_wf_template_id;

    -- Delegate to wf_submit: handles instance creation, approver resolution,
    -- multi-approver fan-out, audit log, first-approver task_assigned
    -- notification, duplicate-instance guard, and
    -- wf_sync_module_status('submitted') → sets Pending + locked = true.
    PERFORM wf_submit(
      p_template_code => v_template_code,
      p_module_code   => 'employee_hire',
      p_record_id     => p_employee_id,
      p_metadata      => jsonb_build_object(
        'employee_id', v_emp.employee_id,
        'name',        v_emp.name
      )
    );

    -- Stamp submitted_at (wf_sync_module_status does not set this column).
    UPDATE employees SET submitted_at = NOW() WHERE id = p_employee_id;

    -- Notify the initiator that their submission was received.
    SELECT id INTO v_instance_id
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status NOT IN ('approved', 'rejected', 'withdrawn')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_instance_id IS NOT NULL THEN
      PERFORM wf_queue_notification(
        v_instance_id,
        'hire.submitted',
        auth.uid(),
        '{}'::jsonb
      );
    END IF;

  -- ── 5b. DIRECT mode ───────────────────────────────────────────────────────
  ELSIF v_mode = 'direct' THEN

    UPDATE employees SET submitted_at = NOW() WHERE id = p_employee_id;
    PERFORM wf_activate_employee(p_employee_id);

  ELSE
    RAISE EXCEPTION 'Unexpected submission mode: %', v_mode
      USING ERRCODE = 'internal_error';
  END IF;

END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submits a Draft or Incomplete hire record for approval (workflow mode) or '
  'activates it directly (direct mode). '
  'Ownership: only the creator, a user with hire_employee.edit_all_pending, or '
  'a super admin may submit. '
  'Mig 262: fixed get_hire_submission_mode() call — zero args, not one. '
  'The mode is determined from the submitter''s workflow assignment, not the '
  'employee record. Bug introduced in mig 254, carried through 260 and 261.';


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'submit_hire'
  ) THEN
    RAISE EXCEPTION 'ABORT: submit_hire not found after migration.';
  END IF;

  -- Confirm get_hire_submission_mode still has zero-arg signature
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname  = 'public'
      AND  p.proname  = 'get_hire_submission_mode'
      AND  p.pronargs = 0
  ) THEN
    RAISE EXCEPTION
      'ABORT: get_hire_submission_mode() zero-arg version not found — '
      'definition may have been altered.';
  END IF;

  RAISE NOTICE 'Migration 262 verified: submit_hire patched, get_hire_submission_mode() signature confirmed.';
END;
$$;
