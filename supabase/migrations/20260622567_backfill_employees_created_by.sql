-- Migration 567 — Backfill employees.created_by for pre-mig-253 records
-- ──────────────────────────────────────────────────────────────────────
-- Mig 253 added the created_by column and a BEFORE INSERT trigger to stamp it,
-- but did not backfill existing rows — they remain NULL.
-- Mig 416 added a legacy bypass: created_by IS NULL lets any hire_employee.view
-- holder see the record, defeating the ownership filter for old records.
-- This migration backfills created_by from workflow_instances.submitted_by
-- (the profile who first submitted the hire workflow for the employee).
-- Records with no workflow history (never submitted Drafts) remain NULL —
-- they are genuinely unclaimed and keep the legacy bypass.

-- ── Pass 1: backfill from workflow_instances (submitted employees) ────────────
-- Use the earliest employee_hire instance per employee so the original
-- submitter is stamped, not a later resubmission by a different user.
UPDATE employees e
SET    created_by = wi.submitted_by
FROM (
  SELECT DISTINCT ON (record_id)
         record_id,
         submitted_by
  FROM   workflow_instances
  WHERE  module_code = 'employee_hire'
  ORDER  BY record_id, created_at ASC
) wi
WHERE e.id          = wi.record_id
  AND e.created_by  IS NULL
  AND e.status      IN ('Draft', 'Incomplete', 'Pending', 'Rejected');

-- ── Pass 2: backfill from workflow_action_log (belt-and-suspenders) ──────────
-- For any remaining NULL rows that have an action_log entry (e.g. auto-skipped
-- workflows that never created an instance row), stamp from the earliest log.
UPDATE employees e
SET    created_by = wal.actor_id
FROM (
  SELECT DISTINCT ON (wi2.record_id)
         wi2.record_id,
         wal2.actor_id
  FROM   workflow_action_log wal2
  JOIN   workflow_instances  wi2  ON wi2.id = wal2.instance_id
  WHERE  wi2.module_code = 'employee_hire'
  ORDER  BY wi2.record_id, wal2.created_at ASC
) wal
WHERE e.id         = wal.record_id
  AND e.created_by IS NULL
  AND e.status     IN ('Draft', 'Incomplete', 'Pending', 'Rejected');

-- ── Verification ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_total    integer;
  v_backfilled integer;
  v_still_null integer;
BEGIN
  SELECT COUNT(*) INTO v_total
  FROM employees WHERE status IN ('Draft','Incomplete','Pending','Rejected');

  SELECT COUNT(*) INTO v_backfilled
  FROM employees WHERE status IN ('Draft','Incomplete','Pending','Rejected') AND created_by IS NOT NULL;

  SELECT COUNT(*) INTO v_still_null
  FROM employees WHERE status IN ('Draft','Incomplete','Pending','Rejected') AND created_by IS NULL;

  RAISE NOTICE 'Migration 567: pipeline records total=%, backfilled=%, still_null=% (genuinely unclaimed)',
    v_total, v_backfilled, v_still_null;
END;
$$;
