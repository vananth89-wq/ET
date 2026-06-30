-- =============================================================================
-- Migration 598: get_stalled_workflows()
--
-- Returns workflow instances that are still 'in_progress' but have no pending
-- tasks — all tasks are approved or cancelled, meaning wf_advance_instance
-- stalled silently and never completed the instance.
--
-- Used by the Workflow Operations admin page to surface and fix stalled
-- workflows without requiring SQL access.
--
-- Super-admin only.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_stalled_workflows()
RETURNS TABLE (
  instance_id   uuid,
  module_code   text,
  record_id     uuid,
  template_name text,
  subject_name  text,
  submitted_at  timestamptz,
  last_acted_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    wi.id                                         AS instance_id,
    wi.module_code,
    wi.record_id,
    wt.name                                       AS template_name,
    COALESCE(subj_emp.name, sub_emp.name)         AS subject_name,
    wi.created_at                                 AS submitted_at,
    MAX(task.acted_at)                            AS last_acted_at
  FROM workflow_instances wi
  JOIN workflow_templates  wt       ON wt.id  = wi.template_id
  JOIN profiles            sub_p    ON sub_p.id = wi.submitted_by
  JOIN employees           sub_emp  ON sub_emp.id = sub_p.employee_id
  LEFT JOIN profiles       subj_p   ON subj_p.id  = wi.subject_profile_id
                                   AND wi.subject_profile_id IS DISTINCT FROM wi.submitted_by
  LEFT JOIN employees      subj_emp ON subj_emp.id = subj_p.employee_id
  LEFT JOIN workflow_tasks task     ON task.instance_id = wi.id
  WHERE wi.status = 'in_progress'
    AND is_super_admin()
  GROUP BY wi.id, wt.name, subj_emp.name, sub_emp.name
  HAVING COUNT(*) FILTER (WHERE task.status = 'pending') = 0
     AND COUNT(*) FILTER (WHERE task.status IN ('approved', 'cancelled')) > 0
  ORDER BY wi.created_at;
$$;

COMMENT ON FUNCTION get_stalled_workflows() IS
  'Mig 598: returns in_progress instances with no pending tasks — stalled by '
  'wf_advance_instance failing to complete. Super-admin only.';

REVOKE ALL     ON FUNCTION get_stalled_workflows() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_stalled_workflows() TO authenticated;
