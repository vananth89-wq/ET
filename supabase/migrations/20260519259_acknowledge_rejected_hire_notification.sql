-- Migration 259: acknowledge_rejected_hire — queue hire.rejection_acknowledged notification
-- ─────────────────────────────────────────────────────────────────────────────
--
-- PROBLEM (Gap 16)
-- acknowledge_rejected_hire() soft-deletes the pre-hire record after a hard
-- rejection, but never queues any notification. The approver who rejected the
-- request has no way of knowing the initiator has seen the decision and closed
-- the record. The rejection cycle stays open from the approver's perspective.
--
-- SOLUTION
-- 1. Seed a new hire.rejection_acknowledged notification template.
-- 2. Rewrite acknowledge_rejected_hire() to:
--      a. Look up the workflow instance (for the instance_id required by
--         wf_queue_notification).
--      b. Find the actor who performed the 'rejected' action (from
--         workflow_action_log) — this is the approver to notify.
--      c. Queue hire.rejection_acknowledged to that approver after the
--         soft-delete completes.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── Step 1: seed notification template ────────────────────────────────────────

INSERT INTO workflow_notification_templates (code, title_tmpl, body_tmpl)
VALUES (
  'hire.rejection_acknowledged',
  'Hire rejection acknowledged: {{name}}',
  'The initiator has acknowledged the rejection of the new hire request for '
  '{{name}} ({{employee_id}}). The record has been closed. No further action is required.'
)
ON CONFLICT (code) DO UPDATE
  SET title_tmpl = EXCLUDED.title_tmpl,
      body_tmpl  = EXCLUDED.body_tmpl;


-- ── Step 2: rewrite acknowledge_rejected_hire ─────────────────────────────────

CREATE OR REPLACE FUNCTION acknowledge_rejected_hire(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status      text;
  v_instance_id uuid;
  v_rejector_id uuid;
BEGIN
  -- ── Guard 1: caller must be the workflow submitter or hold hire_employee.edit ──
  IF NOT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code  = 'employee_hire'
      AND  record_id    = p_employee_id
      AND  submitted_by = auth.uid()
      AND  status       = 'rejected'
  ) AND NOT user_can('hire_employee', 'edit', NULL) THEN
    RAISE EXCEPTION
      'Not authorised to acknowledge rejection for employee %.',
      p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Guard 2: employee must exist and must not be Active ───────────────────────
  SELECT status::text INTO v_status
  FROM   employees
  WHERE  id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employee % not found.', p_employee_id;
  END IF;

  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'Cannot soft-delete an Active employee record (employee %).',
      p_employee_id;
  END IF;

  -- ── Look up the rejected workflow instance ─────────────────────────────────
  SELECT id INTO v_instance_id
  FROM   workflow_instances
  WHERE  module_code = 'employee_hire'
    AND  record_id   = p_employee_id
    AND  status      = 'rejected'
  ORDER BY created_at DESC
  LIMIT 1;

  -- ── Find the approver who performed the rejection ──────────────────────────
  -- Pick the most recent 'rejected' action from the audit log.
  IF v_instance_id IS NOT NULL THEN
    SELECT actor_id INTO v_rejector_id
    FROM   workflow_action_log
    WHERE  instance_id = v_instance_id
      AND  action      = 'rejected'
    ORDER BY created_at DESC
    LIMIT 1;
  END IF;

  -- ── Soft-delete ────────────────────────────────────────────────────────────
  UPDATE employees
  SET    deleted_at = now(),
         updated_at = now()
  WHERE  id = p_employee_id;

  -- ── Notify the rejecting approver ─────────────────────────────────────────
  -- Only queue if we resolved both the instance and the rejector. If either is
  -- NULL (e.g. legacy record with no audit trail) we skip silently rather than
  -- error — the soft-delete has already succeeded.
  IF v_instance_id IS NOT NULL AND v_rejector_id IS NOT NULL THEN
    PERFORM wf_queue_notification(
      v_instance_id,
      'hire.rejection_acknowledged',
      v_rejector_id,
      '{}'::jsonb
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION acknowledge_rejected_hire(uuid) IS
  'Soft-deletes a pre-hire employee record after the workflow instance was '
  'hard-rejected (status = rejected). Distinct from wf_withdraw because '
  'terminal instances cannot be touched by wf_withdraw. '
  'Guard 1: caller must be the original submitter of the rejected instance '
  'or hold hire_employee.edit. '
  'Guard 2: employee must not be Active (prevents accidental deletion). '
  'Sets employees.deleted_at = now(); satellite data becomes invisible via '
  'existing RLS policies which all check deleted_at IS NULL. '
  'Mig 259: now queues hire.rejection_acknowledged to the rejecting approver '
  'so they know the cycle is closed. Skipped silently if instance/rejector '
  'cannot be resolved (legacy records without audit trail).';

REVOKE ALL ON FUNCTION acknowledge_rejected_hire(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION acknowledge_rejected_hire(uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM workflow_notification_templates
    WHERE  code = 'hire.rejection_acknowledged'
  ) THEN
    RAISE EXCEPTION 'ABORT: hire.rejection_acknowledged template not found after migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.routines
    WHERE  routine_schema = 'public'
      AND  routine_name   = 'acknowledge_rejected_hire'
  ) THEN
    RAISE EXCEPTION 'ABORT: acknowledge_rejected_hire not found after migration.';
  END IF;

  RAISE NOTICE 'Migration 259 verified: template seeded and function present.';
END;
$$;
