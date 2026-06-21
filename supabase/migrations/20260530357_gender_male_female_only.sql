-- =============================================================================
-- Migration 357 — upsert_personal_info: hire pipeline access + Male/Female gender only
-- =============================================================================
-- 1. Adds hire pipeline access path to upsert_personal_info access guard.
--    Brand-new Draft employees are not yet in target_group_members, so
--    user_can('personal_info','edit', p_employee_id) returns false for them.
--    The hire pipeline path (user_can with NULL + hire_employee.edit) allows
--    HR admins to write personal info for Draft/Incomplete/Pending employees.
--
-- 2. Restricts gender validation to 'Male' and 'Female' only.
--    Existing rows with other values are preserved (historical data).
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id   uuid,
  p_proposed_data jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_row   employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_amendment  boolean;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Path A: HR/admin scoped to employee via target_group
  -- Path B: Hire pipeline — admin with global edit + hire permission on a Draft/Incomplete/Pending employee
  -- Path C: ESS self-edit
  -- Path D: Approver holds a pending task for this employee
  -- Path E: Submitter whose request was sent back
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR (
      -- Hire pipeline: new employee not yet in target_group_members
      user_can('personal_info', 'edit', NULL)
      AND user_can('hire_employee', 'edit', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id         = p_employee_id
          AND  e.status     IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('personal_info.edit')
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_tasks wt
      JOIN   workflow_instances wi ON wi.id = wt.instance_id
      WHERE  wi.record_id   = p_employee_id
        AND  wt.assigned_to = auth.uid()
        AND  wt.status      = 'pending'
    )
    OR EXISTS (
      SELECT 1
      FROM   workflow_instances wi
      WHERE  wi.record_id    = p_employee_id
        AND  wi.submitted_by = auth.uid()
        AND  wi.status       = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'Access denied: you do not have permission to edit personal information for this employee.'
    );
  END IF;

  -- ── 2. Input validation ───────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  IF (p_proposed_data->>'dob') IS NOT NULL
     AND (p_proposed_data->>'dob')::date > CURRENT_DATE
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;

  -- Gender: Male and Female only
  IF (p_proposed_data->>'gender') IS NOT NULL
     AND (p_proposed_data->>'gender') NOT IN ('Male', 'Female')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Invalid gender value.');
  END IF;

  -- ── 3. Fetch current open-ended row ───────────────────────────────────────

  SELECT * INTO v_current_row
  FROM   employee_personal
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 4. Overlap guard ──────────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1
    FROM   employee_personal
    WHERE  employee_id  = p_employee_id
      AND  is_active    = true
      AND  effective_to < '9999-12-31'::date
      AND  effective_to >= p_effective_from
  ) THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'The chosen effective date overlaps with an existing historical record. Choose a later date.'
    );
  END IF;

  -- ── 5. Amendment: close or replace the current open-ended row ─────────────

  IF v_is_amendment THEN
    IF v_current_row.effective_from >= p_effective_from THEN
      DELETE FROM employee_personal WHERE id = v_current_row.id;
    ELSE
      UPDATE employee_personal
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 6. Insert new slice ───────────────────────────────────────────────────

  INSERT INTO employee_personal (
    employee_id,
    name,
    first_name,
    middle_name,
    last_name,
    preferred_name,
    nationality,
    marital_status,
    gender,
    dob,
    photo_url,
    effective_from,
    effective_to,
    is_active,
    created_by,
    updated_by
  ) VALUES (
    p_employee_id,
    COALESCE(p_proposed_data->>'name',           v_current_row.name),
    COALESCE(p_proposed_data->>'first_name',     v_current_row.first_name),
    COALESCE(p_proposed_data->>'middle_name',    v_current_row.middle_name),
    COALESCE(p_proposed_data->>'last_name',      v_current_row.last_name),
    COALESCE(p_proposed_data->>'preferred_name', v_current_row.preferred_name),
    COALESCE(p_proposed_data->>'nationality',    v_current_row.nationality),
    COALESCE(p_proposed_data->>'marital_status', v_current_row.marital_status),
    COALESCE(p_proposed_data->>'gender',         v_current_row.gender),
    COALESCE(
      NULLIF(p_proposed_data->>'dob', '')::date,
      v_current_row.dob
    ),
    COALESCE(p_proposed_data->>'photo_url',      v_current_row.photo_url),
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 7. Sync employees.name (if effective today or past) ───────────────────

  IF p_effective_from <= CURRENT_DATE THEN
    PERFORM set_config('prowess.allow_name_sync', 'true', true);

    UPDATE employees
    SET    name       = COALESCE(
                          compute_full_name(
                            COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name),
                            COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name),
                            COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name)
                          ),
                          COALESCE(p_proposed_data->>'name', v_current_row.name)
                        ),
           updated_at = now()
    WHERE  id = p_employee_id;
  END IF;

  -- ── 8. Return ─────────────────────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',               true,
    'personal_info_id', v_new_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Effective-dated personal info upsert. '
  'Mig 357: gender restricted to Male / Female only.';

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;
