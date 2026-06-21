-- =============================================================================
-- Migration 379 — upsert_personal_info: always sync employees.name immediately
--
-- PROBLEM
-- ───────
-- Step 8 of upsert_personal_info only wrote employees.name when
-- p_effective_from <= CURRENT_DATE. For future-dated saves (or draft employees
-- whose hire date is tomorrow), employees.name stayed NULL until the nightly
-- activation job ran.
--
-- FIX
-- ───
-- Remove the IF p_effective_from <= CURRENT_DATE guard — always update
-- employees.name immediately. Effective-dating, activation, and approval
-- gating are completely unchanged; only the display name cache updates eagerly.
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
  v_current_row   employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_amendment  boolean;
  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
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

  -- ── 2. Input validation ────────────────────────────────────────────────────

  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  IF p_effective_from > '9999-12-30'::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from cannot be the sentinel date.');
  END IF;

  -- first_name required when explicitly provided
  IF (p_proposed_data ? 'first_name')
     AND (p_proposed_data->>'first_name' IS NULL OR trim(p_proposed_data->>'first_name') = '')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'First name is required.');
  END IF;

  IF (p_proposed_data ? 'dob')
     AND (p_proposed_data->>'dob') IS NOT NULL
     AND (p_proposed_data->>'dob') <> ''
     AND (p_proposed_data->>'dob')::date > CURRENT_DATE
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Date of birth cannot be in the future.');
  END IF;

  IF (p_proposed_data ? 'gender')
     AND (p_proposed_data->>'gender') IS NOT NULL
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

  -- ── 5. Resolve name fields (CASE ? pattern for explicit-null-clear) ────────

  v_first_name := CASE WHEN p_proposed_data ? 'first_name'
                       THEN p_proposed_data->>'first_name'
                       ELSE v_current_row.first_name END;

  v_middle_name := CASE WHEN p_proposed_data ? 'middle_name'
                        THEN p_proposed_data->>'middle_name'
                        ELSE v_current_row.middle_name END;

  v_last_name  := CASE WHEN p_proposed_data ? 'last_name'
                       THEN p_proposed_data->>'last_name'
                       ELSE v_current_row.last_name END;

  -- first_name must not end up NULL or empty
  IF v_first_name IS NULL OR trim(v_first_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'First name is required.');
  END IF;

  v_computed_name := compute_full_name(v_first_name, v_middle_name, v_last_name);

  -- ── 6. Close or replace current open-ended row ────────────────────────────

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

  -- ── 7. Insert new slice ────────────────────────────────────────────────────

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
    v_computed_name,
    v_first_name,
    v_middle_name,
    v_last_name,
    CASE WHEN p_proposed_data ? 'preferred_name'
         THEN p_proposed_data->>'preferred_name'
         ELSE v_current_row.preferred_name END,
    CASE WHEN p_proposed_data ? 'nationality'
         THEN p_proposed_data->>'nationality'
         ELSE v_current_row.nationality END,
    CASE WHEN p_proposed_data ? 'marital_status'
         THEN p_proposed_data->>'marital_status'
         ELSE v_current_row.marital_status END,
    CASE WHEN p_proposed_data ? 'gender'
         THEN p_proposed_data->>'gender'
         ELSE v_current_row.gender END,
    CASE WHEN p_proposed_data ? 'dob'
         THEN NULLIF(p_proposed_data->>'dob', '')::date
         ELSE v_current_row.dob END,
    CASE WHEN p_proposed_data ? 'photo_url'
         THEN p_proposed_data->>'photo_url'
         ELSE v_current_row.photo_url END,
    p_effective_from,
    '9999-12-31'::date,
    true,
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  -- ── 8. Always sync employees.name immediately ──────────────────────────────
  -- Previously guarded by p_effective_from <= CURRENT_DATE, which left
  -- employees.name NULL for future-dated saves and draft/pending employees.
  -- Effective-dating and approval gating are unchanged — only the display
  -- name cache is updated eagerly.
  PERFORM set_config('prowess.allow_name_sync', 'true', true);
  UPDATE employees
  SET    name       = v_computed_name,
         updated_at = now()
  WHERE  id = p_employee_id;

  -- ── 9. Return ──────────────────────────────────────────────────────────────

  RETURN jsonb_build_object(
    'ok',               true,
    'personal_info_id', v_new_id,
    'computed_name',    v_computed_name
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Add or amend an effective-dated personal information slice. '
  'Mig 332: accepts first_name (required), middle_name (optional), last_name (optional). '
  'name column is auto-computed via compute_full_name(). '
  'Mig 379: employees.name is now always synced immediately regardless of effective_from.';
