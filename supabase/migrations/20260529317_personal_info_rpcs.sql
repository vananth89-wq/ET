-- =============================================================================
-- Migration 307 — Personal info RPCs
-- =============================================================================
--
-- Three SECURITY DEFINER functions:
--
--   upsert_personal_info(p_employee_id, p_proposed_data, p_effective_from)
--     ├─ Validates access and inputs
--     ├─ Handles first insert (no prior slice) and amendment (close + insert)
--     ├─ Syncs employees.name when effective_from <= today
--     │   (sets prowess.allow_name_sync = 'true' to bypass the guard trigger)
--     └─ Returns {ok, personal_info_id}
--
--   get_current_personal_info(p_employee_id)
--     └─ Returns the single active open-ended row as jsonb
--
--   get_personal_info_history(p_employee_id)
--     └─ Returns all rows ordered by effective_from DESC as jsonb[]
--
-- All three enforce access via user_can('personal_info', ..., employee_id)
-- with an ESS self-path fallback.
-- =============================================================================


-- =============================================================================
-- 1. upsert_personal_info
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
  -- Four paths:
  --   a) HR/admin:   user_can('personal_info', 'edit', employee_id) — Path D
  --   b) ESS self:   employee is editing their own record
  --   c) Approver:   holds a pending workflow task for this employee
  --   d) Sent-back:  submitted a request that is awaiting_clarification
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
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

  -- DOB must not be in the future if provided
  IF (p_proposed_data->>'dob') IS NOT NULL
     AND (p_proposed_data->>'dob')::date > CURRENT_DATE
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;

  -- Gender constraint (matches existing employee_personal check)
  IF (p_proposed_data->>'gender') IS NOT NULL
     AND (p_proposed_data->>'gender') NOT IN ('Male', 'Female', 'Non-binary', 'Prefer not to say')
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

  -- ── 4. Overlap guard (against existing closed historical rows) ─────────────
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
      -- Mig 288 pattern: new effective_from is earlier than or equal to the
      -- current row's start — closing would create an impossible date range.
      -- Delete the current row and insert a full replacement.
      DELETE FROM employee_personal
      WHERE  id = v_current_row.id;

    ELSE
      -- Standard close: set effective_to = p_effective_from - 1 day
      UPDATE employee_personal
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;

  END IF;

  -- ── 6. Insert new slice (inheriting unchanged fields from previous row) ────

  INSERT INTO employee_personal (
    employee_id,
    name,
    middle_name,
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
    -- name: use proposed value if provided, else carry forward
    COALESCE(p_proposed_data->>'name',           v_current_row.name),
    COALESCE(p_proposed_data->>'middle_name',    v_current_row.middle_name),
    COALESCE(p_proposed_data->>'preferred_name', v_current_row.preferred_name),
    -- personal fields: carry forward unchanged fields
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

  -- ── 7. Sync employees.name (if effective today or past) ──
  -- Only sync when the new slice is immediately active.
  -- Future-dated slices (effective_from > today) are picked up by the
  -- nightly activate_personal_info_records() job.

  IF p_effective_from <= CURRENT_DATE THEN
    -- Set session flag so trg_guard_employee_name_sync allows the write
    PERFORM set_config('prowess.allow_name_sync', 'true', true);  -- true = local to transaction

    UPDATE employees
    SET    name        = COALESCE(p_proposed_data->>'name', v_current_row.name),
           updated_at  = now()
    WHERE  id = p_employee_id;
  END IF;

  -- ── 8. Return ──────────────────────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',               true,
    'personal_info_id', v_new_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Add a new effective-dated personal information slice for an employee, or amend '
  'the existing open-ended slice. '
  'For a first insert (no prior slice): simply inserts the new row. '
  'For an amendment: closes the current open-ended row (effective_to = p_effective_from - 1), '
  'then inserts a new open-ended row inheriting unchanged fields from the closed row. '
  'Edge case (mig 288 pattern): if p_effective_from <= current.effective_from, '
  'deletes the current row instead of closing it (avoids effective_order CHECK violation). '
  'Syncs employees.name immediately when effective_from <= CURRENT_DATE. '
  'Future-dated slices are synced to employees by the nightly activate_personal_info_records() job. '
  'Returns {ok: true, personal_info_id} on success. '
  'Returns {ok: false, error} on access denial or validation failure. '
  'Mig 307: initial creation.';

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;


-- =============================================================================
-- 2. get_current_personal_info
-- =============================================================================

CREATE OR REPLACE FUNCTION get_current_personal_info(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN

  -- ── Access guard ──────────────────────────────────────────────────────────
  IF NOT (
    user_can('personal_info', 'view', p_employee_id)
    OR user_can('personal_info', 'edit', p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('personal_info.view')
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
    -- Hire pipeline: HR can see draft records
    OR (
      user_can('personal_info',  'view', NULL)
      AND user_can('hire_employee', 'view', NULL)
      AND EXISTS (
        SELECT 1 FROM employees e
        WHERE  e.id     = p_employee_id
          AND  e.status IN ('Draft', 'Incomplete', 'Pending')
          AND  e.deleted_at IS NULL
      )
    )
  ) THEN
    RETURN NULL;
  END IF;

  -- ── Query: current active slice ───────────────────────────────────────────
  SELECT jsonb_build_object(
    'id',             ep.id,
    'employee_id',    ep.employee_id,
    'name',           ep.name,
    'middle_name',    ep.middle_name,
    'preferred_name', ep.preferred_name,
    'nationality',    ep.nationality,
    'marital_status', ep.marital_status,
    'gender',         ep.gender,
    'dob',            ep.dob,
    'photo_url',      ep.photo_url,
    'effective_from', ep.effective_from,
    'effective_to',   ep.effective_to,
    'is_active',      ep.is_active,
    'created_at',     ep.created_at,
    'created_by',     ep.created_by,
    'updated_at',     ep.updated_at,
    'updated_by',     ep.updated_by
  )
  INTO v_result
  FROM employee_personal ep
  WHERE ep.employee_id  = p_employee_id
    AND ep.effective_to = '9999-12-31'::date
    AND ep.is_active    = true;

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION get_current_personal_info(uuid) IS
  'Returns the single currently-active personal information row for an employee as jsonb, '
  'or NULL if no active row exists or access is denied. '
  'Replaces direct .from(''employee_personal'').select(''*'').eq(''employee_id'', id).maybeSingle() '
  'calls on the frontend — avoids "multiple rows" errors now that the table is multi-row. '
  'Mig 307: initial creation.';

REVOKE ALL     ON FUNCTION get_current_personal_info(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_current_personal_info(uuid) TO authenticated;


-- =============================================================================
-- 3. get_personal_info_history
-- =============================================================================

CREATE OR REPLACE FUNCTION get_personal_info_history(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN

  -- ── Access guard: requires history permission ─────────────────────────────
  IF NOT (
    user_can('personal_info', 'history', p_employee_id)
    OR user_can('personal_info', 'edit',  p_employee_id)
    OR (
      p_employee_id = get_my_employee_id()
      AND has_permission('personal_info.history')
    )
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  -- ── Query: full timeline, newest first ────────────────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',             ep.id,
      'employee_id',    ep.employee_id,
      'name',           ep.name,
      'middle_name',    ep.middle_name,
      'preferred_name', ep.preferred_name,
      'nationality',    ep.nationality,
      'marital_status', ep.marital_status,
      'gender',         ep.gender,
      'dob',            ep.dob,
      'photo_url',      ep.photo_url,
      'effective_from', ep.effective_from,
      'effective_to',   ep.effective_to,
      'is_active',      ep.is_active,
      'created_at',     ep.created_at,
      'created_by',     ep.created_by,
      'updated_at',     ep.updated_at,
      'updated_by',     ep.updated_by
    )
    ORDER BY ep.effective_from DESC
  )
  INTO v_result
  FROM employee_personal ep
  WHERE ep.employee_id = p_employee_id;

  RETURN COALESCE(v_result, '[]'::jsonb);

EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

COMMENT ON FUNCTION get_personal_info_history(uuid) IS
  'Returns all effective-dated personal information rows for an employee, '
  'ordered by effective_from DESC (most recent first). '
  'Includes closed historical rows and the current open-ended row. '
  'Requires personal_info.history permission or personal_info.edit permission. '
  'Returns [] when access is denied. '
  'Mig 307: initial creation.';

REVOKE ALL     ON FUNCTION get_personal_info_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_personal_info_history(uuid) TO authenticated;
