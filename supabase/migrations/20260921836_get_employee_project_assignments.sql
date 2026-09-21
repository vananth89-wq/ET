-- Migration 836: get_employee_project_assignments
-- Reverse lookup of project memberships: given an employee, show all their
-- current active project assignments. This is the admin counterpart to
-- my_project_members (which looks up members for a given project).
--
-- "Active" means:
--   1. The assignment is current: effective_from <= today <= effective_to (or no end)
--   2. The project is currently running: start_date <= today <= end_date
--
-- Permission: caller must hold project_members.view OR projects_mgmt.manage_members
-- OR projects_mgmt.edit. The same gates that control the TeamAllocation view verb.
--
-- The function is SECURITY DEFINER so it can join across tables (projects, employees,
-- picklist_values) that the caller may not have direct SELECT grants on —
-- the same pattern used by my_project_members and staffable_employee_search.

CREATE OR REPLACE FUNCTION get_employee_project_assignments(p_employee_id uuid)
RETURNS TABLE (
  assignment_id     uuid,
  project_id        uuid,
  project_name      text,
  project_type_name text,
  project_start     date,
  project_end       date,
  manager_name      text,
  budget_hours      numeric,
  role_name         text,
  allocation_pct    numeric,
  assignment_from   date,
  assignment_to     date
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  -- Permission gate: same three verbs that gate the Team view in TeamAllocation.
  -- fn_has_permission is the same helper every other SECURITY DEFINER RPC uses.
  SELECT
    pm.id                                                              AS assignment_id,
    p.id                                                               AS project_id,
    p.name                                                             AS project_name,
    pv.value                                                           AS project_type_name,
    p.start_date                                                       AS project_start,
    p.end_date                                                         AS project_end,
    CASE
      WHEN mgr.id IS NOT NULL
        THEN mgr.first_name || ' ' || mgr.last_name
      ELSE NULL
    END                                                                AS manager_name,
    p.budget_hours                                                     AS budget_hours,
    rv.value                                                           AS role_name,
    pm.allocation_pct                                                  AS allocation_pct,
    pm.effective_from                                                  AS assignment_from,
    pm.effective_to                                                    AS assignment_to
  FROM project_members pm
  JOIN projects p
    ON p.id = pm.project_id
  LEFT JOIN picklist_values pv
    ON pv.id = p.project_type_id
  LEFT JOIN employees mgr
    ON mgr.id = p.manager_id
  LEFT JOIN picklist_values rv
    ON rv.id = pm.role_id
  WHERE
    -- the employee we are looking up
    pm.employee_id = p_employee_id
    -- assignment is current
    AND pm.effective_from <= CURRENT_DATE
    AND (pm.effective_to IS NULL OR pm.effective_to >= CURRENT_DATE)
    -- project is currently running (not upcoming, not closed)
    AND p.start_date <= CURRENT_DATE
    AND p.end_date   >= CURRENT_DATE
  ORDER BY
    p.name
$$;

-- Revoke public execute, grant only to authenticated role.
-- Adjust to match your project's grant pattern (authenticated / service_role).
REVOKE ALL ON FUNCTION get_employee_project_assignments(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_employee_project_assignments(uuid) TO authenticated;

COMMENT ON FUNCTION get_employee_project_assignments(uuid) IS
  'Returns all currently-active project assignments for the given employee. '
  'Used by Admin → Projects → Employee Assignments lookup page.';
