-- =============================================================================
-- Migration 497 — Termination Schema Rename + Column Additions
--
-- Changes:
--   1. RENAME termination_date        → separation_date
--   2. RENAME notice_date             → notice_expiry_date
--   3. DROP   resignation_date        (merged into separation_date)
--   4. ADD    notice_period_days_snapshot INT NOT NULL DEFAULT 30
--              — snapshot of employee_employment.notice_period_days at
--                submission time; set by submit_termination RPC (mig 498)
--   5. ADD    submitted_at TIMESTAMPTZ
--              — stamped once when workflow_status transitions DRAFT → PENDING
--   6. DROP/RECREATE constraints referencing resignation_date
--   7. ADD    chk_term_lwd_after_separation (replaces lwd_after_resignation)
--   8. REBUILD indexes:
--              - ix_term_date        → on separation_date
--              - ix_term_scheduled   → on (last_working_date, scheduled_executed)
--                                      with IS NOT NULL guard
--
-- Design context: docs/termination-design.md
--   separation_date  = employee's stated intent (immutable after submission)
--   notice_expiry_date = submission_date + notice_period_days (always computed)
--   last_working_date  = HR-confirmed actual last day; all jobs key on this
--   notice_period_days_snapshot = point-in-time copy for audit
--   submitted_at       = when notice period clock starts
--
-- Safe to run on empty table (dev/test). For production with existing rows,
-- see backfill section (§6) before deploying.
--
-- Previous migration: 20260604496_refid_short_codes.sql
-- Next migration:     20260604498_termination_rpcs_rename.sql
-- =============================================================================


-- =============================================================================
-- 1. Rename termination_date → separation_date
-- =============================================================================

ALTER TABLE employee_terminations
  RENAME COLUMN termination_date TO separation_date;


-- =============================================================================
-- 2. Rename notice_date → notice_expiry_date
-- =============================================================================

ALTER TABLE employee_terminations
  RENAME COLUMN notice_date TO notice_expiry_date;


-- =============================================================================
-- 3. Drop resignation_date
--    Must drop dependent constraints first.
-- =============================================================================

-- Drop constraints that reference resignation_date
ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS chk_term_resignation_self;

ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS chk_term_lwd_after_resignation;

-- Drop the column
ALTER TABLE employee_terminations
  DROP COLUMN IF EXISTS resignation_date;


-- =============================================================================
-- 4. Add notice_period_days_snapshot
--    Nullable initially so existing rows don't break; RPC sets it at INSERT.
--    We tighten to NOT NULL after backfill (§6).
-- =============================================================================

ALTER TABLE employee_terminations
  ADD COLUMN IF NOT EXISTS notice_period_days_snapshot INTEGER;


-- =============================================================================
-- 5. Add submitted_at
--    Set once when workflow_status transitions from DRAFT → PENDING.
--    Trigger below (§5a) handles this automatically.
-- =============================================================================

ALTER TABLE employee_terminations
  ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ;


-- =============================================================================
-- 5a. Trigger: stamp submitted_at on DRAFT → PENDING transition
-- =============================================================================

CREATE OR REPLACE FUNCTION trg_stamp_submitted_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Set submitted_at exactly once when the record first moves to PENDING
  IF NEW.workflow_status = 'PENDING'
     AND (OLD.workflow_status = 'DRAFT' OR OLD.workflow_status IS DISTINCT FROM 'PENDING')
     AND NEW.submitted_at IS NULL
  THEN
    NEW.submitted_at := NOW();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_termination_submitted_at ON employee_terminations;
CREATE TRIGGER trg_termination_submitted_at
  BEFORE UPDATE ON employee_terminations
  FOR EACH ROW EXECUTE FUNCTION trg_stamp_submitted_at();


-- =============================================================================
-- 6. Backfill existing rows
--    For each existing termination, attempt to set notice_period_days_snapshot
--    from the employment satellite row that was active at separation_date.
--    Falls back to 30 if no matching slice found.
-- =============================================================================

UPDATE employee_terminations et
SET    notice_period_days_snapshot = COALESCE(
         (
           SELECT ee.notice_period_days
           FROM   employee_employment ee
           WHERE  ee.employee_id   = et.employee_id
             AND  ee.effective_from <= et.separation_date
             AND  ee.effective_to   >  et.separation_date
           ORDER  BY ee.effective_from DESC
           LIMIT  1
         ),
         30
       ),
       submitted_at = COALESCE(et.submitted_at, et.created_at)
WHERE  notice_period_days_snapshot IS NULL;


-- =============================================================================
-- 7. Tighten notice_period_days_snapshot to NOT NULL now that rows are backfilled
-- =============================================================================

ALTER TABLE employee_terminations
  ALTER COLUMN notice_period_days_snapshot SET NOT NULL,
  ALTER COLUMN notice_period_days_snapshot SET DEFAULT 30;


-- =============================================================================
-- 8. Add / update constraints
-- =============================================================================

-- LWD must be on or after separation_date (replaces chk_term_lwd_after_resignation)
ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS chk_term_lwd_after_separation;

ALTER TABLE employee_terminations
  ADD CONSTRAINT chk_term_lwd_after_separation
    CHECK (
      last_working_date IS NULL
      OR last_working_date >= separation_date
    );

-- Waiver reason required when waived (idempotent re-add in case it was dropped)
ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS chk_term_waiver_reason;

ALTER TABLE employee_terminations
  ADD CONSTRAINT chk_term_waiver_reason
    CHECK (NOT notice_period_waived OR notice_period_waiver_reason IS NOT NULL);


-- =============================================================================
-- 9. Rebuild indexes
-- =============================================================================

-- Drop old indexes that referenced termination_date
DROP INDEX IF EXISTS ix_term_date;
DROP INDEX IF EXISTS ix_term_scheduled;

-- General date index on separation_date
CREATE INDEX IF NOT EXISTS ix_term_separation_date
  ON employee_terminations (separation_date);

-- Scheduler index: key on last_working_date, guard IS NOT NULL
-- (last_working_date defaults to separation_date via RPC but is nullable in schema)
CREATE INDEX IF NOT EXISTS ix_term_scheduled
  ON employee_terminations (last_working_date, scheduled_executed)
  WHERE workflow_status = 'APPROVED'
    AND scheduled_executed = false
    AND last_working_date IS NOT NULL;


-- =============================================================================
-- 10. Update MANAGER_INITIATED check if not already present
--     (mig 491 added it but ALTER COLUMN is idempotent via DROP/ADD)
-- =============================================================================

ALTER TABLE employee_terminations
  DROP CONSTRAINT IF EXISTS employee_terminations_termination_initiation_type_check;

ALTER TABLE employee_terminations
  ADD CONSTRAINT employee_terminations_termination_initiation_type_check
    CHECK (termination_initiation_type IN (
      'SELF', 'HR_INITIATED', 'MANAGER_INITIATED', 'ADMIN_INITIATED', 'SYSTEM_INITIATED'
    ));


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Confirm columns exist with correct names
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'employee_terminations'
  AND  column_name  IN (
    'separation_date', 'notice_expiry_date', 'last_working_date',
    'notice_period_days_snapshot', 'submitted_at', 'resignation_date'
  )
ORDER  BY column_name;
-- Expected: separation_date ✓, notice_expiry_date ✓, last_working_date ✓,
--           notice_period_days_snapshot ✓, submitted_at ✓
--           resignation_date → NOT present

-- Confirm old column is gone
SELECT COUNT(*) AS resignation_date_gone
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'employee_terminations'
  AND  column_name  = 'resignation_date';
-- Expected: 0

-- Confirm scheduler index is on last_working_date
SELECT indexname, indexdef
FROM   pg_indexes
WHERE  schemaname = 'public'
  AND  tablename  = 'employee_terminations'
  AND  indexname  IN ('ix_term_scheduled', 'ix_term_separation_date');

-- Confirm no rows have NULL notice_period_days_snapshot
SELECT COUNT(*) AS null_snapshots
FROM   employee_terminations
WHERE  notice_period_days_snapshot IS NULL;
-- Expected: 0

-- =============================================================================
-- END OF MIGRATION 497
-- =============================================================================
