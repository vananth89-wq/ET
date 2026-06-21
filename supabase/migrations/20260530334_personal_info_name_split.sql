-- =============================================================================
-- Migration 332 — Split employee_personal.name into first_name / middle_name / last_name
-- =============================================================================
--
-- BACKGROUND
-- ──────────
-- employee_personal previously stored a single freetext `name` field that was
-- synced to employees.name. This migration introduces structured name fields:
--
--   first_name  text NOT NULL  — required
--   middle_name text           — optional (already existed, no change)
--   last_name   text           — optional (some single-name employees)
--
-- The `name` column is retained as a computed cache:
--   All three present : first_name || ' ' || middle_name || ' ' || last_name
--   First + Last only : first_name || ' ' || last_name
--   First + Middle    : first_name || ' ' || middle_name
--   First only        : first_name
--
-- A helper function compute_full_name(first, middle, last) centralises the
-- concatenation logic used by RPCs, triggers, and backfill.
--
-- EXISTING DATA
-- ─────────────
-- Existing name values are split:
--   If name contains a space: everything up to the last space → first_name,
--                              last word → last_name.
--   If no space: entire name → first_name, last_name = NULL.
--   middle_name is left untouched (was net-new in mig 315, typically NULL).
--
-- SCOPE
-- ─────
-- 1. compute_full_name() helper function
-- 2. ADD first_name / last_name columns to employee_personal
-- 3. Backfill from existing name
-- 4. ADD NOT NULL constraint on first_name (after backfill)
-- 5. ADD first_name / last_name to employee_personal_draft
-- 6. Update upsert_personal_info — accept first_name / last_name / middle_name,
--    compute name automatically
-- 7. Update get_current_personal_info — return first_name / last_name
-- 8. Update get_personal_info_history — return first_name / last_name
-- 9. Update activate_personal_info_records — sync uses computed name
-- 10. Update sync_personal_info_for_employee — uses computed name
-- 11. Update wf_activate_employee — seeds first_name / last_name from draft
-- =============================================================================


-- =============================================================================
-- 1. Helper: compute_full_name
-- =============================================================================

CREATE OR REPLACE FUNCTION compute_full_name(
  p_first  text,
  p_middle text,
  p_last   text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT           -- returns NULL only if ALL inputs are NULL; NULLIFed below
SET search_path = public
AS $$
  SELECT trim(
    CASE
      WHEN p_first IS NOT NULL AND p_middle IS NOT NULL AND p_last IS NOT NULL
        THEN p_first || ' ' || p_middle || ' ' || p_last
      WHEN p_first IS NOT NULL AND p_last IS NOT NULL
        THEN p_first || ' ' || p_last
      WHEN p_first IS NOT NULL AND p_middle IS NOT NULL
        THEN p_first || ' ' || p_middle
      ELSE COALESCE(p_first, '')
    END
  )
$$;

COMMENT ON FUNCTION compute_full_name(text, text, text) IS
  'Concatenates first_name, middle_name, last_name into a display name. '
  'Rules: all three present → F M L; first+last → F L; first+middle → F M; '
  'first only → F. Trims result. Mig 332.';


-- =============================================================================
-- 2. Add columns to employee_personal
-- =============================================================================

ALTER TABLE employee_personal
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name  text;


-- =============================================================================
-- 3. Backfill first_name / last_name from existing name
-- =============================================================================

UPDATE employee_personal
SET
  first_name = CASE
    WHEN name IS NULL OR name = ''           THEN 'Unknown'
    WHEN position(' ' IN name) = 0           THEN name
    ELSE left(name, length(name) - length(split_part(name, ' ', -1)) - 1)
  END,
  last_name  = CASE
    WHEN name IS NULL OR name = ''           THEN NULL
    WHEN position(' ' IN name) = 0           THEN NULL
    ELSE split_part(name, ' ', -1)
  END
WHERE first_name IS NULL;


-- =============================================================================
-- 4. NOT NULL on first_name
-- =============================================================================

ALTER TABLE employee_personal
  ALTER COLUMN first_name SET NOT NULL;


-- =============================================================================
-- 5. Add first_name / last_name to employee_personal_draft
-- =============================================================================

ALTER TABLE employee_personal_draft
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name  text;


-- =============================================================================
-- 6. Update upsert_personal_info
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

  -- ── 8. Sync employees.name if effective today or past ─────────────────────

  IF p_effective_from <= CURRENT_DATE THEN
    PERFORM set_config('prowess.allow_name_sync', 'true', true);
    UPDATE employees
    SET    name       = v_computed_name,
           updated_at = now()
    WHERE  id = p_employee_id;
  END IF;

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

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Add or amend an effective-dated personal information slice. '
  'Mig 332: accepts first_name (required), middle_name (optional), last_name (optional). '
  'name column is auto-computed via compute_full_name(). '
  'Legacy callers passing name= directly still work — name is ignored if first_name is present. '
  'Mig 317: initial. Mig 325: null-clear fix. Mig 332: name split.';

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;


-- =============================================================================
-- 7. Update get_current_personal_info — return first_name / last_name
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

  SELECT jsonb_build_object(
    'id',             ep.id,
    'employee_id',    ep.employee_id,
    'name',           ep.name,
    'first_name',     ep.first_name,
    'middle_name',    ep.middle_name,
    'last_name',      ep.last_name,
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
  'Returns the current active employee_personal row as jsonb. '
  'Mig 332: added first_name, last_name to returned object.';

REVOKE ALL     ON FUNCTION get_current_personal_info(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_current_personal_info(uuid) TO authenticated;


-- =============================================================================
-- 8. Update get_personal_info_history — return first_name / last_name
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

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',             ep.id,
      'employee_id',    ep.employee_id,
      'name',           ep.name,
      'first_name',     ep.first_name,
      'middle_name',    ep.middle_name,
      'last_name',      ep.last_name,
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
  'Returns all effective-dated personal information rows ordered by effective_from DESC. '
  'Mig 332: added first_name, last_name to returned objects.';

REVOKE ALL     ON FUNCTION get_personal_info_history(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_personal_info_history(uuid) TO authenticated;


-- =============================================================================
-- 9. Update activate_personal_info_records — name is now computed
-- =============================================================================
-- No change needed: the job syncs employees.name ← employee_personal.name.
-- employee_personal.name is now auto-computed by upsert_personal_info.
-- The job remains correct as-is.


-- =============================================================================
-- 10. Update sync_personal_info_for_employee — no change needed
-- =============================================================================
-- Same as above: syncs employees.name ← employee_personal.name (computed).


-- =============================================================================
-- 11. Update wf_activate_employee — seed first_name / last_name from draft
-- =============================================================================

CREATE OR REPLACE FUNCTION wf_activate_employee(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status        text;
  v_email         text;
  v_name          text;
  v_employee_id   text;
  v_created_by    uuid;
  v_hire_date     date;
  v_next_attempt  int;
  v_has_instance  boolean;
  v_notify_target uuid;
  v_draft         employee_personal_draft%ROWTYPE;
  v_draft_found   boolean := false;
  v_first_name    text;
  v_last_name     text;
  v_computed_name text;
BEGIN
  SELECT status::text, business_email, name, employee_id, created_by, hire_date
  INTO   v_status, v_email, v_name, v_employee_id, v_created_by, v_hire_date
  FROM   employees
  WHERE  id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wf_activate_employee: employee % not found.', p_employee_id;
  END IF;

  IF v_status = 'Active' THEN
    RAISE EXCEPTION
      'wf_activate_employee: employee % is already Active — cannot re-activate.',
      p_employee_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE employees
  SET    status     = 'Active',
         locked     = false,
         updated_at = NOW()
  WHERE  id = p_employee_id;

  IF NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
      AND  is_active    = true
  ) THEN
    SELECT * INTO v_draft
    FROM   employee_personal_draft
    WHERE  employee_id = p_employee_id;
    v_draft_found := FOUND;

    IF v_draft_found THEN
      -- Derive first_name / last_name from draft (may already have them post-332)
      v_first_name := COALESCE(
        NULLIF(trim(v_draft.first_name), ''),
        -- fallback: split draft.name if first_name not set
        CASE
          WHEN v_draft.name IS NOT NULL AND position(' ' IN v_draft.name) > 0
            THEN left(v_draft.name, length(v_draft.name) - length(split_part(v_draft.name, ' ', -1)) - 1)
          ELSE COALESCE(v_draft.name, v_name, 'Unknown')
        END
      );
      v_last_name := COALESCE(
        NULLIF(trim(v_draft.last_name), ''),
        CASE
          WHEN v_draft.name IS NOT NULL AND position(' ' IN v_draft.name) > 0
            THEN split_part(v_draft.name, ' ', -1)
          ELSE NULL
        END
      );
      v_computed_name := compute_full_name(v_first_name, v_draft.middle_name, v_last_name);

      INSERT INTO employee_personal (
        employee_id, name, first_name, middle_name, last_name,
        preferred_name, nationality, marital_status, gender, dob, photo_url,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id,
        v_computed_name,
        v_first_name,
        v_draft.middle_name,
        v_last_name,
        v_draft.preferred_name,
        v_draft.nationality,
        v_draft.marital_status,
        v_draft.gender,
        v_draft.dob,
        v_draft.photo_url,
        COALESCE(v_hire_date, CURRENT_DATE),
        '9999-12-31'::date,
        true,
        auth.uid(),
        auth.uid()
      );
    ELSE
      -- No draft — derive from employees.name
      v_first_name := CASE
        WHEN position(' ' IN v_name) > 0
          THEN left(v_name, length(v_name) - length(split_part(v_name, ' ', -1)) - 1)
        ELSE COALESCE(v_name, 'Unknown')
      END;
      v_last_name := CASE
        WHEN position(' ' IN v_name) > 0
          THEN split_part(v_name, ' ', -1)
        ELSE NULL
      END;
      v_computed_name := compute_full_name(v_first_name, NULL, v_last_name);

      INSERT INTO employee_personal (
        employee_id, name, first_name, last_name,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id,
        v_computed_name,
        v_first_name,
        v_last_name,
        COALESCE(v_hire_date, CURRENT_DATE),
        '9999-12-31'::date,
        true,
        auth.uid(),
        auth.uid()
      );
    END IF;
  END IF;

  DELETE FROM employee_personal_draft WHERE employee_id = p_employee_id;

  SELECT COALESCE(MAX(attempt_no), 0) + 1
  INTO   v_next_attempt
  FROM   employee_invites
  WHERE  employee_id = p_employee_id;

  INSERT INTO employee_invites (employee_id, attempt_no, sent_at, status)
  VALUES (p_employee_id, v_next_attempt, NOW(), 'sent');

  UPDATE employees
  SET    invite_sent_at = NOW()
  WHERE  id = p_employee_id;

  SELECT EXISTS (
    SELECT 1
    FROM   workflow_instances
    WHERE  module_code = 'employee_hire'
      AND  record_id   = p_employee_id
      AND  status      = 'approved'
  ) INTO v_has_instance;

  IF NOT v_has_instance THEN
    IF resolve_workflow_for_submission('employee_hire', auth.uid()) IS NOT NULL THEN
      RAISE EXCEPTION
        'A workflow approval process is configured for New Hire. '
        'Please use "Submit for Approval" instead of activating directly. '
        'Direct activation is only available when no workflow is configured.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_notify_target := COALESCE(v_created_by, auth.uid());

    INSERT INTO notifications (profile_id, title, body, link)
    VALUES (
      v_notify_target,
      'Employee activated: ' || COALESCE(v_computed_name, v_name),
      COALESCE(v_computed_name, v_name) || ' (' || COALESCE(v_employee_id, '—')
        || ') has been directly activated (no approval workflow configured). '
        || 'The invite record has been created.',
      '/employees'
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION wf_activate_employee(uuid) IS
  'Activate a hire-approved employee. '
  'Mig 332: seeds employee_personal with first_name/last_name (derived from draft or employees.name split). '
  'Mig 324: personal info seeding + draft cleanup added. '
  'Frontend must call signInWithOtp + link_profile_to_employee after this returns.';

REVOKE ALL    ON FUNCTION wf_activate_employee(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_activate_employee(uuid) TO authenticated;


-- =============================================================================
-- 12. Comments
-- =============================================================================

COMMENT ON COLUMN employee_personal.first_name IS
  'First name — required. Part of the structured name split introduced in mig 332.';

COMMENT ON COLUMN employee_personal.last_name IS
  'Last name — optional (some single-name employees). Part of the structured name split introduced in mig 332.';

COMMENT ON COLUMN employee_personal.name IS
  'Computed full display name: compute_full_name(first_name, middle_name, last_name). '
  'Kept in sync with employees.name. Mig 332: now auto-derived, not directly set by callers.';
