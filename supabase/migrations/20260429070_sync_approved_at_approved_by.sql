-- =============================================================================
-- Migration 070: Populate approved_at / approved_by on expense_reports
--
-- Gap: wf_sync_module_status() only updated expense_reports.status.
--   It never wrote approved_at or approved_by, so the employee header always
--   showed "—" for those fields even after full approval.
--
-- Fix: When p_status = 'approved', also set:
--   approved_at = now()
--   approved_by = the final approver's employee_id
--              (resolved from auth.uid() → profiles → employees)
--
-- All other status transitions (rejected, withdrawn, draft) leave
-- approved_at and approved_by unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_sync_module_status(
  p_module_code text,
  p_record_id   uuid,
  p_status      text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
BEGIN
  IF p_module_code = 'expense_reports' THEN

    -- Resolve final approver's employee_id from their profile (only needed for 'approved')
    IF p_status = 'approved' THEN
      SELECT employee_id INTO v_employee_id
      FROM   profiles
      WHERE  id = auth.uid();
    END IF;

    UPDATE expense_reports
    SET
      status      = p_status::expense_status,
      approved_at = CASE WHEN p_status = 'approved' THEN now()          ELSE approved_at END,
      approved_by = CASE WHEN p_status = 'approved' THEN v_employee_id  ELSE approved_by END,
      updated_at  = now()
    WHERE id = p_record_id;

  -- ── Add further modules here as they are onboarded ───────────────────────
  -- ELSIF p_module_code = 'leave_requests' THEN
  --   UPDATE leave_requests SET status = p_status, updated_at = now()
  --   WHERE id = p_record_id;

  ELSE
    RAISE NOTICE 'wf_sync_module_status: unknown module_code %, record unchanged', p_module_code;
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_sync_module_status(text, uuid, text) IS
  'Updates status (and approved_at/approved_by for the approved transition) on '
  'the source module record after a workflow terminal event. '
  'Fixed in migration 070: approved_at and approved_by now written on approval.';


-- ── Back-fill existing approved records ──────────────────────────────────────
-- For reports already approved before this migration, populate approved_at
-- from the workflow_action_log completed event and approved_by from the last
-- approver's task.
UPDATE expense_reports er
SET
  approved_at = COALESCE(
    er.approved_at,
    (
      SELECT wal.created_at
      FROM   workflow_action_log wal
      JOIN   workflow_instances  wi  ON wi.id = wal.instance_id
      WHERE  wi.module_code = 'expense_reports'
        AND  wi.record_id   = er.id
        AND  wal.action     = 'approved'
      ORDER  BY wal.created_at DESC
      LIMIT  1
    )
  ),
  approved_by = COALESCE(
    er.approved_by,
    (
      SELECT p.employee_id
      FROM   workflow_action_log wal
      JOIN   workflow_instances  wi  ON wi.id  = wal.instance_id
      JOIN   profiles            p   ON p.id   = wal.actor_id
      WHERE  wi.module_code = 'expense_reports'
        AND  wi.record_id   = er.id
        AND  wal.action     = 'approved'
      ORDER  BY wal.created_at DESC
      LIMIT  1
    )
  )
WHERE er.status = 'approved';


-- ── VERIFICATION ──────────────────────────────────────────────────────────────
SELECT id, status, approved_at, approved_by
FROM   expense_reports
WHERE  status = 'approved'
LIMIT  5;
