-- =============================================================================
-- Migration 202: get_workflow_participants — multi-approver support
--
-- PROBLEM
-- ───────
-- get_workflow_participants() (mig 196) returns one object per workflow step.
-- Multi-approver steps (approval_mode IS NOT NULL, mig 200) have multiple
-- co-approvers in workflow_step_approvers. The existing return shape has no
-- place to convey this, so the WorkflowSubmitModal routing chain shows only
-- the step name with no approver chip for multi-approver steps.
--
-- FIX
-- ───
-- Add two optional fields to each step object:
--   approvalMode  — 'ANY_OF' | 'ALL_OF' | null
--   coApprovers   — JSON array of { approverType, resolvedName, resolvedDesignation }
--                   populated only when approvalMode IS NOT NULL.
--                   null for single-approver steps (backward-compatible).
--
-- The existing single-approver fields (resolvedName, resolvedDesignation,
-- hasResolvedPerson) are preserved unchanged for single-approver steps.
-- For multi-approver steps they will be null / false — the frontend should
-- use coApprovers instead.
--
-- HOW
-- ───
-- For each step with approval_mode IS NOT NULL, we build the coApprovers
-- array using a correlated sub-select that loops over workflow_step_approvers
-- and resolves each entry with the same lateral join pattern used for single
-- approvers. p_profile_id is forwarded so MANAGER/DEPT_HEAD can resolve.
-- =============================================================================


DROP FUNCTION IF EXISTS get_workflow_participants(text);
DROP FUNCTION IF EXISTS get_workflow_participants(text, uuid);


CREATE OR REPLACE FUNCTION get_workflow_participants(
  p_module_code text,
  p_profile_id  uuid DEFAULT NULL
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

  -- ── 1. Find the active template ───────────────────────────────────────────
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

  -- ── 2. Build step objects ─────────────────────────────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'stepOrder',     ws.step_order,
      'stepName',      ws.name,
      'approverType',  ws.approver_type,
      'approverRole',  ws.approver_role,
      'isCC',          COALESCE(ws.is_cc, false),

      -- ── Single-approver resolved name (null for multi-approver steps) ─────
      'resolvedName',
        CASE
          WHEN ws.approval_mode IS NOT NULL THEN NULL   -- multi-approver: use coApprovers
          ELSE CASE ws.approver_type
            WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.name, 'Unknown')
            WHEN 'MANAGER'       THEN COALESCE(mgr_emp.name,     'Direct Manager')
            WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.name,     'Dept. Head')
            WHEN 'ROLE'          THEN COALESCE(role_emp.name, role_row.name, ws.approver_role)
            WHEN 'RULE_BASED'    THEN COALESCE(role_row.name, ws.approver_role, ws.name)
            WHEN 'SELF'          THEN COALESCE(self_emp.name, 'You')
            ELSE                      ws.name
          END
        END,

      'resolvedDesignation',
        CASE
          WHEN ws.approval_mode IS NOT NULL THEN NULL
          ELSE CASE ws.approver_type
            WHEN 'SPECIFIC_USER' THEN COALESCE(profile_emp.job_title, profile_emp.designation_label)
            WHEN 'MANAGER'       THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                               'Resolved at submission time')
            WHEN 'DEPT_HEAD'     THEN COALESCE(mgr_emp.job_title, mgr_emp.designation_label,
                                               'Resolved at submission time')
            WHEN 'ROLE'          THEN COALESCE(role_emp.job_title, role_emp.designation_label)
            WHEN 'SELF'          THEN NULL
            ELSE                      NULL
          END
        END,

      'hasResolvedPerson',
        CASE
          WHEN ws.approval_mode IS NOT NULL THEN false
          ELSE CASE ws.approver_type
            WHEN 'SPECIFIC_USER' THEN true
            WHEN 'ROLE'          THEN (role_emp.name IS NOT NULL)
            WHEN 'MANAGER'       THEN (mgr_emp.name  IS NOT NULL)
            WHEN 'DEPT_HEAD'     THEN (mgr_emp.name  IS NOT NULL)
            WHEN 'SELF'          THEN (self_emp.name IS NOT NULL)
            ELSE                      false
          END
        END,

      -- ── Multi-approver fields (mig 202) ───────────────────────────────────
      'approvalMode',  ws.approval_mode,   -- 'ANY_OF' | 'ALL_OF' | null

      'coApprovers',
        CASE
          WHEN ws.approval_mode IS NULL THEN NULL
          ELSE (
            SELECT jsonb_agg(
              jsonb_build_object(
                'approverType', wsa.approver_type,

                'resolvedName',
                  CASE wsa.approver_type
                    WHEN 'SPECIFIC_USER' THEN COALESCE(co_profile.name,  'Unknown')
                    WHEN 'MANAGER'       THEN COALESCE(co_mgr.name,      'Direct Manager')
                    WHEN 'DEPT_HEAD'     THEN COALESCE(co_mgr.name,      'Dept. Head')
                    WHEN 'ROLE'          THEN COALESCE(co_role_emp.name, co_role_row.name, wsa.approver_role)
                    WHEN 'SELF'          THEN COALESCE(co_self.name,     'You')
                    ELSE                      wsa.approver_type
                  END,

                'resolvedDesignation',
                  CASE wsa.approver_type
                    WHEN 'SPECIFIC_USER' THEN COALESCE(co_profile.job_title, co_profile.designation_label)
                    WHEN 'MANAGER'       THEN COALESCE(co_mgr.job_title, co_mgr.designation_label)
                    WHEN 'DEPT_HEAD'     THEN COALESCE(co_mgr.job_title, co_mgr.designation_label)
                    WHEN 'ROLE'          THEN COALESCE(co_role_emp.job_title, co_role_emp.designation_label)
                    ELSE                      NULL
                  END
              )
              ORDER BY wsa.sort_order
            )
            FROM workflow_step_approvers wsa

            -- SPECIFIC_USER: named profile
            LEFT JOIN LATERAL (
              SELECT emp.name, emp.job_title, pv.value AS designation_label
              FROM   profiles         pr
              JOIN   employees        emp ON emp.id  = pr.employee_id
              LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
              WHERE  pr.id = wsa.approver_profile_id
              LIMIT  1
            ) co_profile ON wsa.approver_type = 'SPECIFIC_USER'

            -- MANAGER / DEPT_HEAD: submitter's manager
            LEFT JOIN LATERAL (
              SELECT mgr.name, mgr.job_title, pv.value AS designation_label
              FROM   profiles         sp
              JOIN   employees        se  ON se.id  = sp.employee_id
              JOIN   employees        mgr ON mgr.id = se.manager_id
              LEFT JOIN picklist_values pv ON pv.id  = mgr.designation::uuid
              WHERE  sp.id = p_profile_id
              LIMIT  1
            ) co_mgr ON wsa.approver_type IN ('MANAGER','DEPT_HEAD')
                    AND p_profile_id IS NOT NULL

            -- ROLE: role row lookup
            LEFT JOIN LATERAL (
              SELECT r.id, r.name
              FROM   roles r
              WHERE  r.code = wsa.approver_role AND r.active = true
              LIMIT  1
            ) co_role_row ON wsa.approver_type = 'ROLE'

            -- ROLE: first active holder
            LEFT JOIN LATERAL (
              SELECT emp.name, emp.job_title, pv.value AS designation_label
              FROM   user_roles       ur
              JOIN   profiles         rp  ON rp.id  = ur.profile_id
              JOIN   employees        emp ON emp.id = rp.employee_id
              LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
              WHERE  ur.role_id  = co_role_row.id
                AND  ur.is_active = true
                AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
              ORDER  BY ur.granted_at
              LIMIT  1
            ) co_role_emp ON wsa.approver_type = 'ROLE' AND co_role_row.id IS NOT NULL

            -- SELF: submitter's own name
            LEFT JOIN LATERAL (
              SELECT emp.name, emp.job_title
              FROM   profiles    sp
              JOIN   employees   emp ON emp.id = sp.employee_id
              WHERE  sp.id = p_profile_id
              LIMIT  1
            ) co_self ON wsa.approver_type = 'SELF' AND p_profile_id IS NOT NULL

            WHERE wsa.step_id = ws.id
          )
        END
    )
    ORDER BY ws.step_order
  )
  INTO  v_result
  FROM  workflow_steps ws

  -- ── Single-approver lateral joins (unchanged from mig 196) ─────────────────

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles         pr
    JOIN   employees        emp ON emp.id  = pr.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  pr.id = ws.approver_profile_id
    LIMIT  1
  ) profile_emp ON ws.approver_type = 'SPECIFIC_USER'
               AND ws.approval_mode IS NULL

  LEFT JOIN LATERAL (
    SELECT r.id, r.name
    FROM   roles r
    WHERE  r.code   = ws.approver_role
      AND  r.active = true
    LIMIT  1
  ) role_row ON ws.approver_type IN ('ROLE', 'RULE_BASED')
            AND ws.approval_mode IS NULL

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   user_roles       ur
    JOIN   profiles         rp  ON rp.id  = ur.profile_id
    JOIN   employees        emp ON emp.id = rp.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  ur.role_id   = role_row.id
      AND  ur.is_active  = true
      AND  (ur.expires_at IS NULL OR ur.expires_at > v_today)
    ORDER  BY ur.granted_at
    LIMIT  1
  ) role_emp ON ws.approver_type = 'ROLE' AND role_row.id IS NOT NULL
            AND ws.approval_mode IS NULL

  LEFT JOIN LATERAL (
    SELECT mgr.name, mgr.job_title, pv.value AS designation_label
    FROM   profiles         sp
    JOIN   employees        se  ON se.id  = sp.employee_id
    JOIN   employees        mgr ON mgr.id = se.manager_id
    LEFT JOIN picklist_values pv ON pv.id  = mgr.designation::uuid
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) mgr_emp ON ws.approver_type IN ('MANAGER', 'DEPT_HEAD')
           AND ws.approval_mode IS NULL
           AND p_profile_id IS NOT NULL

  LEFT JOIN LATERAL (
    SELECT emp.name, emp.job_title, pv.value AS designation_label
    FROM   profiles         sp
    JOIN   employees        emp ON emp.id  = sp.employee_id
    LEFT JOIN picklist_values pv ON pv.id  = emp.designation::uuid
    WHERE  sp.id = p_profile_id
    LIMIT  1
  ) self_emp ON ws.approver_type = 'SELF'
            AND ws.approval_mode IS NULL
            AND p_profile_id IS NOT NULL

  WHERE ws.template_id = v_template_id
    AND ws.is_active   = true;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


GRANT EXECUTE ON FUNCTION get_workflow_participants(text, uuid) TO authenticated;


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT proname, prosrc LIKE '%coApprovers%' AS has_co_approvers
FROM   pg_proc
WHERE  proname = 'get_workflow_participants';

-- Expected: 1 row with has_co_approvers = true

-- =============================================================================
-- END OF MIGRATION 202
--
-- After applying:
--   npx supabase gen types typescript --project-id okpnubnswpgybpzgwgtr \
--     > src/types/database.types.ts
-- =============================================================================
