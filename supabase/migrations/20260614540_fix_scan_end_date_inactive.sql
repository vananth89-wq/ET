-- =============================================================================
-- Migration 540: Fix _scan_end_date_inactive — employees.end_date was dropped
--
-- Mig 487 dropped employees.end_date (and employee_employment.end_date) because
-- inactivation is now owned by the Termination module (mig 482+). However
-- _scan_end_date_inactive() (mig 353) still references e.end_date, causing
-- "column e.end_date does not exist" whenever activate_effective_dated_records()
-- runs (nightly cron or manual Run Now from Background Jobs).
--
-- Fix: replace _scan_end_date_inactive with a no-op that returns empty stats.
-- The end_date inactivation path is fully superseded by fn_finalize_termination_execution.
-- =============================================================================

CREATE OR REPLACE FUNCTION _scan_end_date_inactive()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- end_date column was dropped in mig 487 (termination module owns inactivation).
  -- This function is kept as a no-op so activate_effective_dated_records() compiles.
  RETURN jsonb_build_object('rows', 0, 'error_count', 0);
END;
$$;

COMMENT ON FUNCTION _scan_end_date_inactive() IS
  'Mig 540: no-op. employees.end_date dropped in mig 487; '
  'inactivation is now owned by fn_finalize_termination_execution (Termination module).';

-- =============================================================================
-- END OF MIGRATION 540
-- =============================================================================
