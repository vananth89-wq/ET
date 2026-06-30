-- =============================================================================
-- Migration 599: fix get_stuck_hire_activations — exclude Inactive employees
--
-- Bug: terminated employees (status = 'Inactive') were showing up in the
-- "hires approved but not yet activated" banner because the query only
-- filtered e.status != 'Active'. Inactive employees have a legitimate reason
-- for not being Active — they were hired then later terminated.
--
-- Fix: only surface employees whose status is 'Draft' (hire approved but
-- activation genuinely never ran).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_stuck_hire_activations()
RETURNS TABLE (
  employee_id    uuid,
  employee_ref   text,
  name           text,
  business_email text,
  department     text,
  job_title      text,
  approved_at    timestamptz,
  instance_id    uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH latest AS (
    SELECT DISTINCT ON (wi.record_id)
      wi.record_id   AS emp_id,
      wi.id          AS instance_id,
      wi.completed_at
    FROM   workflow_instances wi
    JOIN   employees e ON e.id = wi.record_id
    WHERE  wi.module_code = 'employee_hire'
      AND  wi.status      = 'approved'
      AND  e.status       = 'Draft'      -- only genuinely stuck activations
      AND  e.deleted_at  IS NULL
    ORDER  BY wi.record_id, wi.completed_at DESC
  )
  SELECT
    e.id            AS employee_id,
    e.employee_id   AS employee_ref,
    e.name,
    e.business_email,
    d.name          AS department,
    e.job_title,
    l.completed_at  AS approved_at,
    l.instance_id
  FROM   latest l
  JOIN   employees    e ON e.id  = l.emp_id
  LEFT   JOIN departments d ON d.id = e.dept_id
  ORDER  BY l.completed_at DESC;
$$;

COMMENT ON FUNCTION get_stuck_hire_activations() IS
  'Mig 599: only returns employees with status=Draft (hire approved but '
  'activation never ran). Excludes Inactive (terminated) employees.';

REVOKE ALL     ON FUNCTION get_stuck_hire_activations() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_stuck_hire_activations() TO authenticated;
