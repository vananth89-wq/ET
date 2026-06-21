-- =============================================================================
-- Migration 326 — Fix activate_personal_info_records job scope
-- =============================================================================
--
-- PROBLEM WITH CURRENT IMPLEMENTATION
-- ─────────────────────────────────────
-- The job used WHERE effective_from = CURRENT_DATE. This means:
--   • If the job fails on a given night, those rows are missed permanently —
--     the next run uses tomorrow's date and skips them.
--   • It re-syncs the same employee every day even if already synced (no-op
--     UPDATE but still unnecessary work).
--
-- CORRECT DESIGN
-- ──────────────
-- upsert_personal_info() already syncs employees.name immediately when
-- effective_from <= CURRENT_DATE. The nightly job's only job is to handle
-- the residual case: future-dated rows that became valid at midnight but
-- were not touched by a user (no RPC call fired for them).
--
-- The correct query:
--   Find employees where:
--     1. Their current active employee_personal row has effective_from <= today
--        (i.e. the row is now valid)
--     2. employees.name does NOT match employee_personal.name
--        (i.e. there is actual drift — sync is needed)
--
-- This is exactly the vw_personal_name_drift view — but without the
-- authenticated access restriction (the job runs as superuser via pg_cron).
--
-- Benefits:
--   • Catches missed activations from any past job failure — not just today's
--   • Only updates employees where there is actual drift — no wasted UPDATEs
--   • Scope is naturally limited to affected employees only — not a full scan
--   • Idempotent — running twice does nothing on the second pass
-- =============================================================================

CREATE OR REPLACE FUNCTION activate_personal_info_records()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job_start   timestamptz := clock_timestamp();
  v_rows        integer     := 0;
  v_errors      integer     := 0;
  v_error_text  text        := NULL;
  r             RECORD;
BEGIN

  -- Set session flag — bypasses trg_guard_employee_name_sync for all
  -- employees updated in this transaction
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  -- Find employees where the current active personal_info slice is now valid
  -- (effective_from <= today) but employees.name still shows the old value.
  --
  -- This covers:
  --   a) Future-dated changes that became effective today at midnight
  --   b) Any missed activations from previous job failures (any past date)
  --   c) Drift from direct DB writes that bypassed upsert_personal_info
  --
  -- Scope is limited to employees with actual drift only — not a full table scan.
  FOR r IN
    SELECT
      ep.employee_id,
      ep.name        AS personal_name,
      e.name         AS employees_name
    FROM   employee_personal ep
    JOIN   employees e ON e.id = ep.employee_id
    WHERE  ep.effective_to   = '9999-12-31'::date
      AND  ep.is_active      = true
      AND  ep.effective_from <= CURRENT_DATE
      AND  e.status          = 'Active'
      AND  e.deleted_at      IS NULL
      AND  e.name IS DISTINCT FROM ep.name   -- only sync when there is actual drift
  LOOP
    BEGIN
      UPDATE employees
      SET    name       = r.personal_name,
             updated_at = now()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors     := v_errors + 1;
      v_error_text := COALESCE(v_error_text, '')
                      || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  -- Log run to job_run_log (rows_affected = 0 when system is in sync — normal)
  INSERT INTO job_run_log (
    job_code,
    status,
    started_at,
    finished_at,
    rows_affected,
    error_message
  ) VALUES (
    'activate_personal_info_records',
    CASE WHEN v_errors = 0 THEN 'success' ELSE 'failed' END,
    v_job_start,
    clock_timestamp(),
    v_rows,
    v_error_text
  );

END;
$$;

COMMENT ON FUNCTION activate_personal_info_records() IS
  'Nightly pg_cron job (00:05). Finds Active employees where employees.name '
  'diverges from their current employee_personal row (effective_from <= today). '
  'Only syncs employees with actual drift — idempotent, catches missed '
  'activations from past job failures. '
  'Mig 318: initial (used effective_from = CURRENT_DATE — fragile). '
  'Mig 326: corrected to effective_from <= CURRENT_DATE with drift check — '
  'self-healing, scope-limited to affected employees only.';
