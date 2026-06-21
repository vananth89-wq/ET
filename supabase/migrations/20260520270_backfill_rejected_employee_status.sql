-- Migration 270: Backfill employees.status = 'Rejected' for existing rejected hires
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Migration 269 included a backfill UPDATE but the join condition
--   wi.record_id = e.id::text
-- matched 0 rows because workflow_instances.record_id is stored as text UUID
-- but the cast direction was wrong.  This migration fixes it by casting
-- record_id → uuid in an IN subquery so Postgres can compare properly.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE employees
SET    status     = 'Rejected',
       locked     = true,
       updated_at = now()
WHERE  id IN (
  SELECT record_id::uuid
  FROM   workflow_instances
  WHERE  module_code = 'employee_hire'
    AND  status      = 'rejected'
)
AND  deleted_at IS NULL;

-- Verify
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM   employees e
  JOIN   workflow_instances wi
         ON  wi.record_id::uuid = e.id
         AND wi.module_code     = 'employee_hire'
         AND wi.status          = 'rejected'
  WHERE  e.status    = 'Rejected'
    AND  e.locked    = true
    AND  e.deleted_at IS NULL;

  RAISE NOTICE 'Migration 270: % rejected hire(s) now have status=Rejected + locked=true.', v_count;
END;
$$;
