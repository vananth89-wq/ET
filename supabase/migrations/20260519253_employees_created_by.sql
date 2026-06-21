-- =============================================================================
-- Migration 253: employees.created_by — Gap E
--
-- PROBLEM
-- ───────
-- The employees table has no record of who created a hire record. This means:
--
--   1. submit_hire() has no ownership check — any HR analyst who can view a
--      Draft/Incomplete record can submit it for approval, even if someone else
--      created it. The original comment in mig 218 flagged this explicitly:
--      "A stricter check can be added via a created_by column in a later migration."
--
--   2. wf_activate_employee() direct-activate notification (mig 252) targets
--      auth.uid() — the activating admin — instead of the person who actually
--      created the hire record. If a different admin activates a record they
--      didn't create, the original creator gets no notification.
--
-- FIX
-- ───
-- 1. Add employees.created_by (uuid, FK → profiles, nullable for legacy rows).
--
-- 2. BEFORE INSERT trigger trg_employees_stamp_created_by:
--    Sets NEW.created_by = auth.uid() when the column is not explicitly
--    provided. Fires for every INSERT — covers the frontend's three insert paths
--    (performSave, doAutosave, handleActivate) without any frontend code change.
--    COALESCE preserves an explicitly-passed value (future server-side imports).
--
-- 3. Update submit_hire() to enforce creator ownership:
--    Only the creator OR a user with hire_employee.approve OR a super admin may
--    submit a hire record. Other HR analysts who can view the record but did not
--    create it are blocked.
--
-- 4. Update wf_activate_employee() direct-activate notification (from mig 252)
--    to target created_by (when set) instead of auth.uid(), so the original
--    creator is notified even when a different admin performs the activation.
--
-- BACKWARD COMPATIBILITY
-- ──────────────────────
-- Existing employees rows get created_by = NULL. submit_hire's ownership check
-- treats NULL created_by as "unclaimed" — any authorised user can submit those
-- records, preserving existing behaviour for legacy data.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PART 1 — Add employees.created_by column
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS created_by uuid
    REFERENCES profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN employees.created_by IS
  'Profile UUID of the HR Analyst who created this employee record via the '
  'new hire form. Set automatically by trg_employees_stamp_created_by on '
  'INSERT. NULL for employee records created before mig 253. '
  'Used by submit_hire for ownership enforcement and by wf_activate_employee '
  'to route the direct-activate notification to the original creator.';

-- Index — submit_hire and wf_activate_employee look this up by employee PK
-- (no separate index needed), but an index on created_by is useful for
-- future queries like "show me all hires I created".
CREATE INDEX IF NOT EXISTS idx_employees_created_by
  ON employees (created_by)
  WHERE created_by IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 2 — BEFORE INSERT trigger to stamp created_by
-- ════════════════════════════════════════════════════════════════════════════
--
-- Fires for every INSERT on employees. Sets created_by = auth.uid() unless
-- the caller already provided a value (future server-side import paths).
-- auth.uid() is the authenticated profile calling the API — correct for all
-- three frontend insert paths (performSave, doAutosave, handleActivate).

CREATE OR REPLACE FUNCTION fn_employees_stamp_created_by()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_employees_stamp_created_by() IS
  'BEFORE INSERT trigger function: stamps employees.created_by = auth.uid() '
  'when not explicitly provided by the caller. COALESCE preserves explicit '
  'values so future import RPCs can set a different creator. Mig 253.';

DROP TRIGGER IF EXISTS trg_employees_stamp_created_by ON employees;

CREATE TRIGGER trg_employees_stamp_created_by
BEFORE INSERT ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_employees_stamp_created_by();

COMMENT ON TRIGGER trg_employees_stamp_created_by ON employees IS
  'Auto-stamps created_by on every new employee row. Mig 253.';


-- ════════════════════════════════════════════════════════════════════════════
-- PART 3 — submit_hire: enforce creator ownership
-- ════════════════════════════════════════════════════════════════════════════
--
-- Before this migration, any HR analyst who could view a Draft/Incomplete record
-- could submit it. Now we check: caller must be the creator, OR hold
-- hire_employee.approve (approvers can submit on behalf), OR be a super admin.
-- NULL created_by (legacy records) is treated as unclaimed — any authorised
-- caller may submit, preserving existing behaviour for historical data.

CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status          text;
  v_locked          boolean;
  v_created_by      uuid;
  v_wf_template_id  uuid;
  v_template_code   text;
BEGIN
  -- Caller must be linked to an employee record
  IF get_my_employee_id() IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  -- Fetch employee status, locked flag, and creator
  SELECT status::text, locked, created_by
  INTO   v_status, v_locked, v_created_by
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee record not found.';
  END IF;

  -- Only Draft or Incomplete records can be submitted
  IF v_status NOT IN ('Draft', 'Incomplete') THEN
    RAISE EXCEPTION
      'Only Draft or Incomplete records can be submitted (current status: %).', v_status;
  END IF;

  IF v_locked THEN
    RAISE EXCEPTION 'This record is already submitted and awaiting approval.';
  END IF;

  -- ── Ownership check ────────────────────────────────────────────────────────
  -- Allow:  creator of the record
  --         any user with hire_employee.approve (can act on behalf)
  --         super admins
  -- Deny:   other HR analysts who can view but didn't create this record
  -- NULL created_by (legacy / pre-mig 253 records) → unclaimed, anyone may submit
  IF v_created_by IS NOT NULL
    AND v_created_by != auth.uid()
    AND NOT user_can('hire_employee', 'approve', NULL)
    AND NOT is_super_admin()
  THEN
    RAISE EXCEPTION
      'Only the HR Analyst who created this hire record may submit it for approval. '
      'If you need to submit on their behalf, ask an administrator.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolve workflow template
  v_wf_template_id := resolve_workflow_for_submission('employee_hire', auth.uid());

  IF v_wf_template_id IS NULL THEN
    RAISE EXCEPTION
      'No active workflow is configured for the New Hire module. '
      'Ask your administrator to assign a workflow template to employee_hire.';
  END IF;

  SELECT code INTO v_template_code
  FROM   workflow_templates
  WHERE  id = v_wf_template_id;

  -- Lock and mark Pending
  UPDATE employees
  SET    status     = 'Pending',
         locked     = true,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  -- Start the workflow instance
  PERFORM wf_submit(
    p_template_code => v_template_code,
    p_module_code   => 'employee_hire'::text,
    p_record_id     => p_employee_id,
    p_metadata      => jsonb_build_object(
      'employee_id', (SELECT employee_id FROM employees WHERE id = p_employee_id),
      'name',        (SELECT name        FROM employees WHERE id = p_employee_id)
    )
  );
END;
$$;

COMMENT ON FUNCTION submit_hire(uuid) IS
  'Submit a Draft/Incomplete employee record for approval. '
  'Mig 253: enforces creator ownership — only the HR analyst who created '
  'the record (employees.created_by) may submit it, unless the caller holds '
  'hire_employee.approve or is a super admin. NULL created_by (legacy records) '
  'is treated as unclaimed so existing behaviour is preserved. '
  'Marks record Pending+locked and starts the workflow instance.';

REVOKE ALL   ON FUNCTION submit_hire(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_hire(uuid) TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- PART 4 — wf_activate_employee: notify created_by on direct-activate path
-- ════════════════════════════════════════════════════════════════════════════
--
-- Replaces the version from mig 252.
-- The only change: in the direct-activate notification block, target
-- COALESCE(v_created_by, auth.uid()) — notify the original creator when known,
-- fall back to the activating admin when created_by is NULL (legacy records).

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
  v_next_attempt  int;
  v_has_instance  boolean;
  v_notify_target uuid;
BEGIN
  -- ── Fetch employee ────────────────────────────────────────────────────────
  SELECT status::text, business_email, name, employee_id, created_by
  INTO   v_status, v_email, v_name, v_employee_id, v_created_by
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  -- ── Re-activation guard ───────────────────────────────────────────────────
  -- Prevent duplicate invite sends if called on an already-Active employee.
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

  -- ── Step 2: Record invite attempt ─────────────────────────────────────────
  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  -- ── Step 3: Stamp invite_sent_at ─────────────────────────────────────────
  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  -- ── Step 4: Engine-path vs. direct-path detection ─────────────────────────
  -- wf_advance_instance sets instance.status = 'approved' BEFORE calling
  -- wf_sync_module_status → wf_activate_employee. Engine path: approved
  -- instance already exists → skip guard (hire.completed already delivered).
  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    -- ── Guard: block direct-activate when a workflow is configured ─────────
    IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
      RAISE EXCEPTION
        'A workflow approval process is configured for New Hire. '
        'Please use "Submit for Approval" instead of activating directly. '
        'Direct activation is only available when no workflow is configured.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- ── No workflow configured — direct-activate is intentional ────────────
    -- Notify the original creator (when known) so they hear about the
    -- activation even if a different admin performed it.
    -- Fall back to auth.uid() for legacy records with NULL created_by.
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
  'Activate a hire-approved employee: sets status=Active, locked=false, records invite. '
  'Mig 252 guard: blocks direct-activate when a workflow is configured. '
  'Mig 253: direct-activate notification targets employees.created_by (original creator) '
  'rather than auth.uid(), falling back to auth.uid() for legacy records with NULL created_by. '
  'Engine path (approved instance exists): no guard, no duplicate notification. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL   ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Column exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public'
      AND  table_name   = 'employees'
      AND  column_name  = 'created_by'
  ) THEN
    RAISE EXCEPTION 'ABORT: employees.created_by column not found.';
  END IF;

  -- Trigger exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE  trigger_name   = 'trg_employees_stamp_created_by'
      AND  event_object_table = 'employees'
  ) THEN
    RAISE EXCEPTION 'ABORT: trg_employees_stamp_created_by trigger not found.';
  END IF;

  -- Functions present
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'submit_hire')         THEN
    RAISE EXCEPTION 'ABORT: submit_hire not found.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'wf_activate_employee') THEN
    RAISE EXCEPTION 'ABORT: wf_activate_employee not found.';
  END IF;

  RAISE NOTICE 'Migration 253 verified: created_by column, trigger, and updated RPCs present.';
END;
$$;

-- Confirm column is in place
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'employees'
  AND  column_name  = 'created_by';

-- =============================================================================
-- END OF MIGRATION 253
--
-- After this migration:
--   • Every new employee row has created_by = auth.uid() stamped automatically.
--   • Existing rows have created_by = NULL (treated as unclaimed by submit_hire).
--   • submit_hire blocks HR analysts from submitting records they didn't create,
--     unless they hold hire_employee.approve or are super admins.
--   • wf_activate_employee direct-activate notification reaches the original
--     creator rather than whoever clicked Activate.
--
-- No frontend changes required:
--   • All three insert paths (performSave, doAutosave, handleActivate) already
--     call supabase.from('employees').insert(...) — the trigger fires on all of them.
--   • The frontend does not need to pass created_by explicitly.
--
-- Future:
--   • Gap E + Gap D together: direct-activate notification now correctly reaches
--     the hire record's creator via employees.created_by.
-- =============================================================================
