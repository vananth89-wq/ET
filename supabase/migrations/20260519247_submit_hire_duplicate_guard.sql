-- =============================================================================
-- Migration 247: Duplicate-submission guard for submit_hire
--
-- PROBLEM
-- ───────
-- submit_hire only checks:
--   • employee.status IN ('Draft', 'Incomplete')
--   • employee.locked = false
--
-- The locked flag is the primary protection, but it can drift out of sync if:
--   a) a previous transaction partial-failed after locking the row but before
--      the workflow instance was created
--   b) a manual data fix reset locked without checking for an active instance
--   c) a direct authenticated API call bypasses the UI flow
--
-- In all these cases a second parallel workflow instance could be created for
-- the same employee record, putting it in an inconsistent state.
--
-- FIXES
-- ─────
-- 1. Partial unique index on workflow_instances — enforced at the storage level,
--    applies to ALL modules (expense_reports, profile_*, employee_hire, future).
--    Blocks any INSERT/UPDATE that would leave two active instances for the same
--    (module_code, record_id) pair.
--
--    Active = status IN ('in_progress', 'awaiting_clarification')
--
--    Safe for all modules:
--      expense_reports  — one report, one UUID, one active instance ✓
--      profile_*        — record_id = workflow_pending_changes.id, each change
--                         request gets its own new UUID → multiple in-flight
--                         profile changes are fine (different record_ids) ✓
--      employee_hire    — one employee, one UUID, one active instance ✓
--
-- 2. Explicit guard in submit_hire — fires before wf_submit is called so the
--    caller receives a clear human-readable error rather than a raw constraint
--    violation message.
--
-- WHY BOTH
-- ────────
-- The index is the hard enforcement; the function guard is the UX layer. A
-- direct supabase.rpc('submit_hire', ...) call from the frontend displays
-- rpcError.message — the guard ensures that message is useful.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Partial unique index — one active instance per (module, record)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS uq_workflow_instances_one_active_per_record
ON workflow_instances (module_code, record_id)
WHERE status IN ('in_progress', 'awaiting_clarification');

COMMENT ON INDEX uq_workflow_instances_one_active_per_record IS
  'Enforces that at most one active workflow instance (in_progress or '
  'awaiting_clarification) exists per (module_code, record_id) pair. '
  'Prevents duplicate parallel submissions caused by race conditions, '
  'stale locked flags, or direct API calls. Covers all workflow modules. '
  'Mig 247.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Update submit_hire — add explicit in-progress duplicate guard
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emp_id          uuid;
  v_status          text;
  v_locked          boolean;
  v_wf_template_id  uuid;
  v_template_code   text;
BEGIN
  -- Caller must be linked to an employee
  v_emp_id := get_my_employee_id();
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Your profile is not linked to an employee record.';
  END IF;

  -- Fetch employee status + locked (row-level lock prevents concurrent submissions)
  SELECT status::text, locked
  INTO   v_status, v_locked
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee record not found.';
  END IF;

  -- Status guard: only Draft or Incomplete records can be submitted
  IF v_status NOT IN ('Draft', 'Incomplete') THEN
    RAISE EXCEPTION
      'Only Draft or Incomplete records can be submitted (current status: %).', v_status;
  END IF;

  -- Locked guard: belt-and-suspenders against double-submit
  IF v_locked THEN
    RAISE EXCEPTION 'This record is already submitted and awaiting approval.';
  END IF;

  -- ── Duplicate-instance guard (Gap 4) ─────────────────────────────────────
  -- Belt-and-suspenders check: ensure no active workflow instance exists for
  -- this employee, even if the locked flag is somehow out of sync.
  -- Catches: stale locked=false after a partial failure, direct API calls,
  -- and any other path that could leave locked=false with an active instance.
  IF EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      IN ('in_progress', 'awaiting_clarification')
  ) THEN
    RAISE EXCEPTION
      'A workflow is already active for this employee (in review or awaiting clarification). '
      'Withdraw the existing submission before starting a new one.';
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
  'Marks it Pending+locked and starts the workflow instance. '
  'Guards: status IN (Draft, Incomplete), locked=false, no active instance. '
  'Mig 224: removed p_submitted_by from wf_submit call. '
  'Mig 247: added duplicate-instance guard (Gap 4) — explicit check for any '
  'existing in_progress or awaiting_clarification instance before submitting. '
  'Backed by uq_workflow_instances_one_active_per_record partial unique index.';

REVOKE ALL ON FUNCTION submit_hire(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION submit_hire(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- Verification
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Confirm index exists
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_indexes
    WHERE  schemaname = 'public'
      AND  indexname  = 'uq_workflow_instances_one_active_per_record'
  ) THEN
    RAISE EXCEPTION
      'ABORT: uq_workflow_instances_one_active_per_record index not found after migration.';
  END IF;

  -- Confirm function exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'submit_hire'
  ) THEN
    RAISE EXCEPTION 'ABORT: submit_hire not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 247 verified: index and function both present.';
END;
$$;

-- =============================================================================
-- END OF MIGRATION 247
--
-- After this migration:
--   workflow_instances  — partial unique index prevents any two active instances
--                         for the same (module_code, record_id) pair, across all
--                         modules (employee_hire, expense_reports, profile_*, …)
--   submit_hire         — explicit guard raises a clear error if an active
--                         instance already exists, before attempting wf_submit.
--
-- No schema changes. No type regen needed.
-- No frontend changes needed — AddEmployee.tsx already surfaces rpcError.message.
-- =============================================================================
