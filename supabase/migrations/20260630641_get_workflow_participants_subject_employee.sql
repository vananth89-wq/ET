-- =============================================================================
-- Mig 641: get_workflow_participants — add SUBJECT_EMPLOYEE support
--
-- SUBJECT_EMPLOYEE steps show the step name instead of the resolved employee
-- because get_workflow_participants has no SUBJECT_EMPLOYEE CASE branch.
-- Add it: resolve from p_subject_employee_id when supplied, fall back to
-- submitter profile (self-service).
-- =============================================================================

CREATE OR REPLACE FUNCTION get_workflow_participants(
  p_module_code         text,
  p_profile_id          uuid DEFAULT NULL,
  p_subject_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template_id uuid;
  v_today       date := current_date;
  v_result      jsonb;
BEGIN
  SELECT wf_template_id
  INTO   v_template_id
  FROM   workflow_assignments
  WHERE  module_code    = p_module_code
    AND  is_active      = true
    AND  effective_from <= v_today
    AND  (effective_to IS NULL OR effective_to >= v_today)
  LIMIT  1;

  IF v_template_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',    ws.step_order,
      'stepName',     ws.name,
      'approverType', ws.approver_type,
      'approverRole', ws.approver_role,
      'isCC',         COALESCE(ws.is_cc, false),
      'approvalMode', ws.approval_mode,

      'resolvedName',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER'    THEN COALESCE(profile_emp.name, 'Unknown')
          WHEN 'MANAGER'          THEN COALESCE(mgr_emp.name, mgr_emp_from_profile.name, 'Direct Manager')
          WHEN 'DEPT_HEAD'        THEN COALESCE(mgr_emp.name, mgr_emp_from_profile.name, 'Dept. Head')
          WHEN 'ROLE'             THEN COALESCE(role_row.name, ws.approver_role)
          WHEN 'RULE_BASED'       THEN COALESCE(role_row.name, ws.approver_role, ws.name)
          WHEN 'SELF'             THEN COALESCE(self_emp.name, 'You')
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.name, self_emp.name, 'Employee')
          ELSE                         ws.name
        END,

      'resolvedDesignation',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER'    THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
          WHEN 'MANAGER'          THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                               mgr_emp_from_profile.job_title, mgr_emp_from_profile.designation_label,
                                               'Resolved at submission time')
          WHEN 'DEPT_HEAD'        THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                               mgr_emp_from_profile.job_title, mgr_emp_from_profile.designation_label,
                                               'Resolved at submission time')
          WHEN 'ROLE'             THEN
            CASE WHEN ws.approval_mode = 'ALL_OF'
                 THEN 'All active members must approve'
                 ELSE 'All active members — first to approve wins'
            END
          WHEN 'SELF'             THEN NULL
          WHEN 'SUBJECT_EMPLOYEE' THEN COALESCE(subject_emp.job_title, 'Subject Employee')
          ELSE                         NULL
        END,

      'hasResolvedPerson',
        CASE ws.approver_type
          WHEN 'SPECIFIC_USER'    THEN true
          WHEN 'ROLE'             THEN true
          WHEN 'MANAGER'          THEN (COALESCE(mgr_emp.name, mgr_emp_from_profile.name) IS NOT NULL)
          WHEN 'DEPT_HEAD'        THEN (COALESCE(mgr_emp.name, mgr_emp_from_profile.name) IS NOT NULL)
          WHEN 'SELF'             THEN (self_emp.name IS NOT NULL)
          WHEN 'SUBJECT_EMPLOYEE' THEN (COALESCE(subject_emp.name, self_emp.name) IS NOT NULL)
          ELSE                         false
        END,

      'willBeSkipped',
        CASE
          WHEN ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
               AND (p_profile_id IS NOT NULL OR p_subject_employee_id IS NOT NULL)
               AND COALESCE(mgr_emp.name, mgr_emp_from_profile.name) IS NULL
            THEN true
          ELSE false
        END,

      'roleMembers',
        CASE ws.approver_type
          WHEN 'ROLE' THEN (
            SELECT jsonb_agg(
              jsonb_build_object('name', emp.name, 'jobTitle', emp.job_title)
              ORDER BY emp.name
            )
            FROM   user_roles ur
            JOIN   roles      r   ON r.id  = ur.role_id
            JOIN   profiles   p   ON p.id  = ur.profile_id
            JOIN   employees  emp ON emp.id = p.employee_id
            WHERE  r.code       = ws.approver_role
              AND  r.active     = true
              AND  ur.is_active = true
              AND  (ur.expires_at IS NULL OR ur.expires_at > CURRENT_DATE)
          )
          ELSE NULL::jsonb
        END,

      'coApprovers', NULL::jsonb
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles pr
    JOIN   employees emp ON emp.id = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'

  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code = ws.approver_role AND r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type IN ('ROLE', 'RULE_BASED')

  -- MANAGER / DEPT_HEAD: subject employee supplied (admin-on-behalf)
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   employees subj
    JOIN   employees mgr ON mgr.id = subj.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  subj.id = p_subject_employee_id
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
           AND p_subject_employee_id IS NOT NULL

  -- MANAGER / DEPT_HEAD: self-service
  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles sp
    JOIN   employees se  ON se.id = sp.employee_id
    JOIN   employees mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id = mgr.designation::uuid
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) mgr_emp_from_profile ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
                         AND p_subject_employee_id IS NULL
                         AND p_profile_id IS NOT NULL

  -- SELF always resolves to the submitter (p_profile_id), never the subject employee.
  -- SUBJECT_EMPLOYEE has its own lateral below.
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   profiles sp
    JOIN   employees emp ON emp.id = sp.employee_id
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'
            AND p_profile_id IS NOT NULL

  -- SUBJECT_EMPLOYEE: resolve from subject employee when supplied
  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title
    FROM   employees emp
    WHERE  emp.id = p_subject_employee_id
    LIMIT  1
  ) subject_emp ON ws.approver_type = 'SUBJECT_EMPLOYEE'
               AND p_subject_employee_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION get_workflow_participants(text, uuid, uuid) IS
  'Mig 635: SELF resolves subject employee when p_subject_employee_id supplied. '
  'Mig 641: SUBJECT_EMPLOYEE added — resolves to subject employee (admin-on-behalf) '
  'or submitter profile (self-service).';
