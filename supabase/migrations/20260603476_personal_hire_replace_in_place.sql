-- =============================================================================
-- Migration 476 — upsert_personal_info: replace-in-place for hire pipeline
-- =============================================================================
--
-- PROBLEM
-- ───────
-- For Draft / Incomplete / Pending employees the amendment logic inside
-- upsert_personal_info creates a historical slice whenever effective_from
-- changes between saves:
--
--   Save 1 (personal section, hireDate not yet set):
--     → effective_from = 2026-06-04 (today, or skipped with mig 442 fix)
--
--   Save 2 (after employment section fills hire_date = 2026-07-01):
--     → existing row has effective_from 2026-06-04 < new effective_from 2026-07-01
--     → amendment logic: closes the old row (effective_to = 2026-06-30)
--                         inserts new row (effective_from = 2026-07-01)
--     → result: two rows for a brand-new hire ✗
--
--   Save 3 (user edits hire_date → 2026-08-01):
--     → same problem: third row created ✗
--
-- ROOT CAUSE
-- ──────────
-- The amendment logic was designed for ACTIVE employees where history is
-- intentional.  For hire pipeline records there is no meaningful history yet —
-- the employee has never been active, so all prior slices are noise.
--
-- FIX
-- ───
-- Add a hire-pipeline branch BEFORE the normal amendment case:
--   IF employee.status IN ('Draft','Incomplete','Pending') THEN
--     DELETE any existing open-ended row for this employee (regardless of its
--     effective_from) and fall through to the INSERT — no historical slice.
--
-- This guarantees exactly ONE employee_personal row per hire record, with
-- effective_from always equal to the current hire_date passed from the frontend.
--
-- EXISTING BEHAVIOUR UNCHANGED
-- ─────────────────────────────
-- Active / Inactive employees follow the original amendment path.  The only
-- employees affected are those still in the hire pipeline.
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
  v_is_hire       boolean;   -- true when employee is in the hire pipeline

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
  v_old_name      text;
BEGIN

  -- ── 1. Access guard ────────────────────────────────────────────────────────
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

  -- ── 3. Detect hire pipeline ────────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE id = p_employee_id AND status IN ('Draft', 'Incomplete', 'Pending')
  ) INTO v_is_hire;

  -- ── 4. Fetch current open-ended row ───────────────────────────────────────
  SELECT * INTO v_current_row
  FROM   employee_personal
  WHERE  employee_id  = p_employee_id
    AND  effective_to = '9999-12-31'::date
    AND  is_active    = true
  FOR UPDATE;

  v_is_amendment := FOUND;

  -- ── 5. Amendment handling ─────────────────────────────────────────────────
  IF v_is_amendment THEN

    IF v_is_hire THEN
      -- ── HIRE PIPELINE: replace the existing open-ended row in place ───────
      -- Never create a historical slice for an employee who has never been active.
      -- Simply delete the old open-ended row; the INSERT below writes the fresh
      -- row with the correct effective_from (= hire_date from the frontend).
      DELETE FROM employee_personal WHERE id = v_current_row.id;

    ELSIF v_current_row.effective_from >= p_effective_from THEN
      -- Effective date moved backwards → replace the current row entirely
      DELETE FROM employee_personal WHERE id = v_current_row.id;

    ELSE
      -- ── ACTIVE EMPLOYEE AMENDMENT: close the current slice ────────────────
      -- Overlap guard
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

      UPDATE employee_personal
      SET    effective_to = p_effective_from - interval '1 day',
             updated_by   = auth.uid(),
             updated_at   = now()
      WHERE  id = v_current_row.id;
    END IF;
  END IF;

  -- ── 6. Compute name from first / middle / last ────────────────────────────
  v_first_name  := NULLIF(trim(COALESCE(p_proposed_data->>'first_name',  v_current_row.first_name,  '')), '');
  v_middle_name := NULLIF(trim(COALESCE(p_proposed_data->>'middle_name', v_current_row.middle_name, '')), '');
  v_last_name   := NULLIF(trim(COALESCE(p_proposed_data->>'last_name',   v_current_row.last_name,   '')), '');

  v_computed_name := trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name));
  IF v_computed_name = '' THEN v_computed_name := NULL; END IF;

  v_old_name := v_current_row.name;

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
  -- Update the denormalized name on the employees row when the new slice is
  -- current (effective_from <= today) and a name was computed.
  IF p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL THEN
    UPDATE employees
    SET    name       = v_computed_name,
           updated_at = NOW()
    WHERE  id = p_employee_id
      AND  (name IS DISTINCT FROM v_computed_name);
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_new_id);
END;
$$;

REVOKE ALL ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Upserts personal info for an employee. '
  'Hire pipeline (Draft/Incomplete/Pending): replaces the existing open-ended row in place — '
  'no historical slices are created; effective_from always equals hire_date. '
  'Active employees: closes the current open-ended slice and inserts a new one (normal amendment). '
  'Mig 476: added hire-pipeline replace-in-place branch.';
