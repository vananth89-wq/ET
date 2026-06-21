-- =============================================================================
-- Migration 462 — Fix _sync_job_relationships_today: broken HAVING clause
--
-- PROBLEM
-- ───────
-- Mig 461 introduced _sync_job_relationships_today with a HAVING clause that
-- references e.pm01_manager_id, e.pm02_manager_id, etc. — columns from the
-- employees JOIN that are not in GROUP BY. PostgreSQL cannot resolve these in
-- HAVING because they are neither aggregated nor in the GROUP BY list.
-- This would throw: ERROR: column "e.pm01_manager_id" must appear in GROUP BY
-- or be used in an aggregate function.
--
-- FIX
-- ───
-- Rewrite using a CTE:
--   1. sat CTE: aggregate satellite values per (employee_id, set_id)
--   2. Main SELECT: JOIN sat with employees, filter on drift in WHERE clause
-- This is unambiguous and mirrors the pattern used by _sync_employment_today.
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_job_relationships_today(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
BEGIN
  PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

  FOR r IN
    WITH sat AS (
      SELECT
        s.employee_id,
        s.id AS set_id,
        MAX(CASE WHEN i.relationship_code = 'PM01' THEN i.manager_employee_id END) AS pm01,
        MAX(CASE WHEN i.relationship_code = 'PM02' THEN i.manager_employee_id END) AS pm02,
        MAX(CASE WHEN i.relationship_code = 'PM03' THEN i.manager_employee_id END) AS pm03,
        MAX(CASE WHEN i.relationship_code = 'OM01' THEN i.manager_employee_id END) AS om01,
        MAX(CASE WHEN i.relationship_code = 'OM02' THEN i.manager_employee_id END) AS om02,
        MAX(CASE WHEN i.relationship_code = 'OM03' THEN i.manager_employee_id END) AS om03
      FROM   employee_job_relationship_set s
      LEFT JOIN employee_job_relationship_item i ON i.set_id = s.id
      WHERE  s.effective_from <= p_as_of_date
        AND  s.effective_to   >= p_as_of_date
        AND  s.is_active       = true
      GROUP BY s.employee_id, s.id
    )
    SELECT
      sat.employee_id,
      sat.set_id,
      sat.pm01, sat.pm02, sat.pm03,
      sat.om01, sat.om02, sat.om03
    FROM   sat
    JOIN   employees e ON e.id = sat.employee_id
    WHERE  e.deleted_at IS NULL
      AND  e.status IN ('Active', 'Inactive')   -- skip Draft/Pending (mig 461)
      AND (
        e.pm01_manager_id IS DISTINCT FROM sat.pm01
        OR e.pm02_manager_id IS DISTINCT FROM sat.pm02
        OR e.pm03_manager_id IS DISTINCT FROM sat.pm03
        OR e.om01_manager_id IS DISTINCT FROM sat.om01
        OR e.om02_manager_id IS DISTINCT FROM sat.om02
        OR e.om03_manager_id IS DISTINCT FROM sat.om03
      )
  LOOP
    BEGIN
      UPDATE employees
      SET    pm01_manager_id = r.pm01,
             pm02_manager_id = r.pm02,
             pm03_manager_id = r.pm03,
             om01_manager_id = r.om01,
             om02_manager_id = r.om02,
             om03_manager_id = r.om03,
             updated_at      = NOW()
      WHERE  id = r.employee_id;

      v_rows := v_rows + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors     := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_job_relationships_today(date) IS
  'Nightly helper: syncs employees pm01–om03_manager_id from the active '
  'job-relationship set for p_as_of_date. Active/Inactive employees only. '
  'Called by activate_effective_dated_records(). '
  'Mig 461: initial (broken HAVING). Mig 462: rewritten with CTE.';

DO $$
BEGIN
  RAISE NOTICE 'Migration 462: _sync_job_relationships_today rewritten with CTE — HAVING bug fixed.';
END;
$$;
