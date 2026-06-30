-- =============================================================================
-- Migration 588: get_employee_terminations — hide WITHDRAWN and REJECTED records
--
-- Previously the RPC returned the latest non-REVERSED record, which included
-- WITHDRAWN and REJECTED. The portlet then showed those records with an
-- "Initiate Termination" button alongside them, creating visual clutter.
--
-- Fix: exclude WITHDRAWN and REJECTED from the portlet query.
-- The portlet will now show NULL (→ blank state with "Initiate Termination")
-- after a withdrawal, giving a clean slate to resubmit.
-- History is still accessible via get_termination_history (unaffected).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_terminations(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_termination jsonb;
  v_reversal    jsonb;
  v_attachments jsonb;
BEGIN
  IF NOT (
    user_can('termination', 'view', p_employee_id)
    OR user_can('termination', 'view', NULL)
    OR get_my_employee_id() = p_employee_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: termination.view required.');
  END IF;

  -- Latest active termination (excludes terminal / non-actionable statuses)
  SELECT to_jsonb(t) INTO v_termination
  FROM (
    SELECT
      et.id,
      et.employee_id,
      et.separation_date,
      et.notice_expiry_date,
      et.notice_period_days_snapshot,
      et.termination_reason_code,
      et.termination_initiation_type,
      et.last_working_date,
      et.notice_period_waived,
      et.notice_period_waiver_reason,
      et.eligible_for_rehire,
      et.regrettable_termination,
      et.comments,
      et.workflow_status,
      et.workflow_instance_id,
      et.approved_at,
      et.approved_by,
      et.final_settlement_processed,
      et.final_settlement_date,
      et.submitted_at,
      et.created_at,
      et.created_by,
      et.updated_at
    FROM employee_terminations et
    WHERE et.employee_id     = p_employee_id
      AND et.workflow_status NOT IN ('REVERSED', 'WITHDRAWN', 'REJECTED')
    ORDER BY et.created_at DESC
    LIMIT 1
  ) t;

  IF v_termination IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'termination', NULL);
  END IF;

  -- Active reversal for the returned termination
  SELECT to_jsonb(r) INTO v_reversal
  FROM (
    SELECT
      etr.id,
      etr.termination_id,
      etr.reversal_reason,
      etr.comments,
      etr.workflow_status,
      etr.workflow_instance_id,
      etr.created_at,
      etr.created_by
    FROM employee_termination_reversals etr
    WHERE etr.termination_id  = (v_termination->>'id')::uuid
      AND etr.workflow_status NOT IN ('WITHDRAWN', 'REJECTED')
    ORDER BY etr.created_at DESC
    LIMIT 1
  ) r;

  RETURN jsonb_build_object(
    'ok',          true,
    'termination', v_termination,
    'reversal',    v_reversal
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION get_employee_terminations(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_terminations(uuid) TO authenticated;

COMMENT ON FUNCTION get_employee_terminations(uuid) IS
  'Mig 588: excludes WITHDRAWN and REJECTED records from portlet view. '
  'Clean slate shown after withdrawal — user can resubmit immediately. '
  'History still available via get_termination_history.';
