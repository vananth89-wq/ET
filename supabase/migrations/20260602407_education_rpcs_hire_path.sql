-- =============================================================================
-- Migration 407 — Fix get_employee_education / get_employee_education_history:
--                 add hire-pipeline access path for pending employees
-- =============================================================================
-- Root cause: get_employee_education only checked:
--   user_can('education', 'view', p_employee_id) OR user_can('education', 'view', NULL)
--
-- The second clause (NULL target) is Path B in user_can — it requires
-- target_group_id IS NULL in role_permissions (admin-scoped permission).
-- HR approvers who have education.view scoped to a target group do NOT satisfy
-- this. Pending hire employees are also typically absent from target_group_members
-- cache, so Path D (user_can('education','view', employee_id)) fails too.
--
-- Bank accounts uses the correct two-condition hire path:
--   user_can('bank_accounts', 'view', NULL)
--   AND user_can('hire_employee', 'view', NULL)
--   AND employee.status IN ('Draft','Incomplete','Pending')
--
-- Education was missing this entirely. The symptom: get_employee_education
-- returns { ok: false } for the approver → EducationPortlet treats it as
-- empty → auto-open logic fires → blank "Add Education Record" form appears
-- instead of the existing records.
--
-- Fix: add the same hire-pipeline path to both read RPCs, matching bank exactly.
-- =============================================================================


-- ── 1. get_employee_education ─────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_education(uuid, boolean);

CREATE OR REPLACE FUNCTION get_employee_education(
  p_employee_id      uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (
    user_can('education', 'view', p_employee_id)
    OR user_can('education', 'edit', p_employee_id)
    OR p_employee_id = get_my_employee_id()
    OR user_can('education', 'view', NULL)
    OR user_can('education', 'edit', NULL)
    OR (
      -- hire pipeline: same guard as bank_accounts / dependents RPCs
      user_can('education', 'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
    OR (
      -- hire pipeline fallback: approver who can view hires but may not have
      -- education.view NULL (education added after their role was configured)
      user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  SELECT jsonb_build_object(
    'ok',        true,
    'education', COALESCE(jsonb_agg(row_data ORDER BY
      row_data->>'is_highest_qualification' DESC,
      row_data->>'end_date'   DESC NULLS FIRST,
      row_data->>'start_date' DESC
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      to_jsonb(ee.*) ||
      jsonb_build_object(
        'attachments', COALESCE((
          SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.uploaded_at)
          FROM   employee_education_attachments a
          WHERE  a.education_id = ee.id
            AND  a.is_active    = true
        ), '[]'::jsonb)
      ) AS row_data
    FROM employee_education ee
    WHERE ee.employee_id = p_employee_id
      AND (p_include_inactive OR ee.is_active = true)
  ) sub;

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION get_employee_education(uuid, boolean) IS
  'Returns all education records for an employee with embedded attachments. '
  'Sort: highest qualification first, then end_date DESC, start_date DESC. '
  'Pass p_include_inactive=true to include soft-deleted rows. '
  'Mig 396: initial. Mig 407: hire-pipeline path — hire_employee.view NULL + pending status.';

REVOKE ALL     ON FUNCTION get_employee_education(uuid, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_education(uuid, boolean) TO authenticated;


-- ── 2. get_employee_education_history ────────────────────────────────────────

DROP FUNCTION IF EXISTS get_employee_education_history(uuid);

CREATE OR REPLACE FUNCTION get_employee_education_history(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    user_can('education', 'history', p_employee_id)
    OR user_can('education', 'view',    p_employee_id)
    OR user_can('education', 'edit',    p_employee_id)
    OR p_employee_id = get_my_employee_id()
    OR user_can('education', 'history', NULL)
    OR user_can('education', 'view',    NULL)
    OR user_can('education', 'edit',    NULL)
    OR (
      user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
      )
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied.');
  END IF;

  RETURN get_employee_education(p_employee_id, true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION get_employee_education_history(uuid) IS
  'Returns all education records including inactive (soft-deleted). '
  'Delegates to get_employee_education(p_employee_id, true). '
  'Mig 396: initial. Mig 407: hire-pipeline path — hire_employee.view NULL + pending status.';

REVOKE ALL     ON FUNCTION get_employee_education_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_employee_education_history(uuid) TO authenticated;
