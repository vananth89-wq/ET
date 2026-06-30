-- Migration 581: Deduplicate get_stuck_hire_activations
-- An employee can have multiple approved workflow_instances (e.g. resubmitted
-- workflows) which caused duplicates in the banner. Keep only the latest
-- approved instance per employee.

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
      AND  e.status      != 'Active'
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

REVOKE ALL     ON FUNCTION get_stuck_hire_activations() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_stuck_hire_activations() TO authenticated;

DO $$
BEGIN
  RAISE NOTICE 'Migration 581: get_stuck_hire_activations deduplicated — OK';
END;
$$;
