-- =============================================================================
-- Migration 394 — upsert_personal_info: restore hire pipeline access path
-- =============================================================================
-- Bug: mig 380 (bulk_picklist_label_resolution) rewrote upsert_personal_info
-- and dropped the hire pipeline access path.
-- Brand-new Draft employees are not yet in target_group_members, so
-- user_can('personal_info', 'edit', p_employee_id) returns false.
-- HR Analysts with global personal_info.edit get "Access denied" when saving
-- personal info on Next during the hire wizard.
--
-- Fix: restore Path B — if caller has global personal_info.edit AND the target
-- is Draft/Incomplete/Pending, allow the upsert.
-- Same pattern as upsert_employment_info (mig 358/389).
-- =============================================================================

CREATE OR REPLACE FUNCTION upsert_personal_info(
  p_employee_id    uuid,
  p_proposed_data  jsonb,
  p_effective_from date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- (keep full function body — only the access guard changes)
  v_current_row   employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_amendment  boolean;

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
  v_old_name      text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
  -- Path A: scoped HR — employee already in their target group
  -- Path B: hire pipeline — brand-new Draft employee not yet in target_group_members
  -- Path C: ESS self-edit
  -- Path D: approver holds a pending workflow task
  -- Path E: sent-back initiator
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR (
      user_can('personal_info', 'edit', NULL)
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

  -- ── 2. Input validation ────────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
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

  -- ── 5. Amendment: close or replace current open-ended row ─────────────────

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

  -- ── 6. Compute name from first/middle/last ────────────────────────────────

  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   '')), '');

  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  -- ── 7. Insert new slice ───────────────────────────────────────────────────

  INSERT INTO employee_personal (
    employee_id,
    first_name, middle_name, last_name, name,
    nationality, marital_status, gender, dob, photo_url,
    effective_from, effective_to, is_active,
    created_by, updated_by
  ) VALUES (
    p_employee_id,
    v_first_name,
    v_middle_name,
    v_last_name,
    v_computed_name,
    COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_current_row.nationality),
    COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_current_row.marital_status),
    COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_current_row.gender),
    COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_current_row.dob),
    COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_current_row.photo_url),
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 8. Sync employees.name ────────────────────────────────────────────────

  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    SELECT name INTO v_old_name FROM employees WHERE id = p_employee_id;
    IF v_old_name IS DISTINCT FROM v_computed_name THEN
      UPDATE employees SET name = v_computed_name, updated_at = now()
      WHERE  id = p_employee_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'personal_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Mig 394: restored hire pipeline Path B — any user with global personal_info.edit '
  'can upsert personal info for Draft/Incomplete/Pending employees. '
  'This was dropped in mig 380 causing HR Analysts to get Access denied during hire wizard.';
