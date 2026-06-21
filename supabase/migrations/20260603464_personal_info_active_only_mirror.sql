-- =============================================================================
-- Migration 464 — Personal info sync: Active/Inactive guard (inline + nightly)
--
-- PROBLEM
-- ───────
-- Two places sync employees.name from the personal info satellite, both without
-- a status guard — they fire for Draft/Incomplete/Pending employees too:
--
-- A) upsert_personal_info (mig 454), step 7:
--    IF v_is_latest AND p_effective_from <= CURRENT_DATE AND v_computed_name IS NOT NULL
--    → stamps employees.updated_at on every personal info save during hire wizard,
--      contributing to the optimistic lock invalidation problem (same root cause
--      as the employment mirror, fixed in mig 460).
--
-- B) _sync_personal_info_today (mig 353):
--    No status filter — runs nightly for all employees including Draft/Pending.
--    Would detect name drift (satellite updated, base table not yet) and stamp
--    updated_at at 00:05, undoing the mig 460/464 fix for sessions spanning midnight.
--
-- FIX
-- ───
-- A) upsert_personal_info: add AND v_existing_status IN ('Active','Inactive')
--    to the step 7 mirror guard. Read v_existing_status from employees before
--    the mirror block (same pattern as mig 460 for employment).
--    During hire pipeline the satellite is sole source of truth for name.
--    mapEmployee already reads from employee_personal satellite directly, so
--    the hire wizard shows the correct name without the mirror.
--
-- B) _sync_personal_info_today: add AND e.status IN ('Active','Inactive')
--    to the WHERE clause. Consistent with _sync_employment_today (mig 459)
--    and _sync_job_relationships_today (mig 461/462).
-- =============================================================================


-- =============================================================================
-- A. upsert_personal_info — add status guard to mirror block
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
  v_case          text;
  v_target        employee_personal%ROWTYPE;
  v_current       employee_personal%ROWTYPE;
  v_first         employee_personal%ROWTYPE;
  v_new_id        uuid;
  v_is_latest     boolean;

  v_first_name    text;
  v_middle_name   text;
  v_last_name     text;
  v_computed_name text;
  v_old_name      text;
  v_existing_status employee_status;   -- ← added (mig 464)
BEGIN
  -- ── 1. Access guard ────────────────────────────────────────────────────────
  IF NOT (
    user_can('personal_info', 'edit', p_employee_id)
    OR EXISTS (
        SELECT 1 FROM employees e WHERE e.id = p_employee_id
          AND e.status IN ('Draft','Incomplete','Pending') AND e.deleted_at IS NULL
    )
    OR (p_employee_id = get_my_employee_id() AND has_permission('personal_info.edit'))
    OR EXISTS (
      SELECT 1 FROM workflow_tasks wt JOIN workflow_instances wi ON wi.id = wt.instance_id
      WHERE wi.record_id = p_employee_id AND wt.assigned_to = auth.uid() AND wt.status = 'pending'
    )
    OR EXISTS (
      SELECT 1 FROM workflow_instances wi
      WHERE wi.record_id = p_employee_id AND wi.submitted_by = auth.uid()
        AND wi.status = 'awaiting_clarification'
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Access denied: you do not have permission to edit personal information for this employee.');
  END IF;

  -- ── 2. Input validation ────────────────────────────────────────────────────
  IF p_effective_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'effective_from is required.');
  END IF;

  -- ── 3. Lock all slices ─────────────────────────────────────────────────────
  PERFORM id FROM employee_personal
  WHERE employee_id = p_employee_id ORDER BY effective_from FOR UPDATE;

  -- ── 4. Case detection ──────────────────────────────────────────────────────
  SELECT * INTO v_target FROM employee_personal
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_first FROM employee_personal
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_first.effective_from THEN
      v_case := 'prepend'; v_target := v_first;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_target FROM employee_personal
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to != '9999-12-31'::date
      AND effective_to >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT * INTO v_current FROM employee_personal
    WHERE employee_id = p_employee_id
      AND effective_to = '9999-12-31'::date AND is_active = true;
    IF FOUND THEN
      v_case := 'amendment'; v_target := v_current;
    ELSE
      v_case := 'gap_fill';
      SELECT * INTO v_target FROM employee_personal
      WHERE employee_id = p_employee_id ORDER BY effective_from DESC LIMIT 1;
    END IF;
  END IF;

  -- ── 5. Derive name ─────────────────────────────────────────────────────────
  v_first_name  := COALESCE(NULLIF(p_proposed_data->>'first_name',  ''), v_target.first_name);
  v_middle_name := COALESCE(NULLIF(p_proposed_data->>'middle_name', ''), v_target.middle_name);
  v_last_name   := COALESCE(NULLIF(p_proposed_data->>'last_name',   ''), v_target.last_name);
  v_computed_name := NULLIF(trim(concat_ws(' ', v_first_name, v_middle_name, v_last_name)), '');

  -- ── 6. Execute by case ────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    UPDATE employee_personal SET
      first_name      = v_first_name,
      middle_name     = v_middle_name,
      last_name       = v_last_name,
      name            = v_computed_name,
      nationality     = COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      gender          = COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      dob             = COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_target.dob),
      marital_status  = COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      photo_url       = COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      updated_at      = NOW(), updated_by = auth.uid()
    WHERE id = v_target.id
    RETURNING id INTO v_new_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, gender, dob, marital_status, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_target.dob),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      p_effective_from, v_target.effective_from - interval '1 day',
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;

  ELSIF v_case = 'split' THEN
    DECLARE v_inherited_end date := v_target.effective_to; BEGIN
      UPDATE employee_personal
      SET effective_to = p_effective_from - interval '1 day',
          updated_at = NOW(), updated_by = auth.uid()
      WHERE id = v_target.id;

      INSERT INTO employee_personal (
        employee_id, first_name, middle_name, last_name, name,
        nationality, gender, dob, marital_status, photo_url,
        effective_from, effective_to, is_active, created_by, updated_by
      ) VALUES (
        p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
        COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
        COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
        COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_target.dob),
        COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
        COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
        p_effective_from, v_inherited_end,
        v_target.is_active, auth.uid(), auth.uid()
      ) RETURNING id INTO v_new_id;
    END;

  ELSE -- amendment / gap_fill
    IF v_case = 'amendment' THEN
      IF v_current.effective_from >= p_effective_from THEN
        DELETE FROM employee_personal WHERE id = v_current.id;
      ELSE
        UPDATE employee_personal
        SET effective_to = p_effective_from - interval '1 day',
            is_active = false, inactive_at = NOW(),
            updated_at = NOW(), updated_by = auth.uid()
        WHERE id = v_current.id;
      END IF;
    END IF;

    INSERT INTO employee_personal (
      employee_id, first_name, middle_name, last_name, name,
      nationality, gender, dob, marital_status, photo_url,
      effective_from, effective_to, is_active, created_by, updated_by
    ) VALUES (
      p_employee_id, v_first_name, v_middle_name, v_last_name, v_computed_name,
      COALESCE(NULLIF(p_proposed_data->>'nationality',    ''), v_target.nationality),
      COALESCE(NULLIF(p_proposed_data->>'gender',         ''), v_target.gender),
      COALESCE(NULLIF(p_proposed_data->>'dob',            '')::date, v_target.dob),
      COALESCE(NULLIF(p_proposed_data->>'marital_status', ''), v_target.marital_status),
      COALESCE(NULLIF(p_proposed_data->>'photo_url',      ''), v_target.photo_url),
      p_effective_from, '9999-12-31'::date,
      true, auth.uid(), auth.uid()
    ) RETURNING id INTO v_new_id;
  END IF;

  -- ── 7. Mirror sync — Active/Inactive only, most-recent slice (mig 464) ────
  -- During hire pipeline (Draft/Incomplete/Pending), employees.name is kept
  -- current by mapEmployee reading from employee_personal satellite directly.
  -- The mirror is suppressed here to avoid stamping employees.updated_at on
  -- every personal info save, which would invalidate the optimistic lock token.
  v_is_latest := NOT EXISTS (
    SELECT 1 FROM employee_personal
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  );

  SELECT status INTO v_existing_status FROM employees WHERE id = p_employee_id;

  IF v_is_latest
     AND p_effective_from <= CURRENT_DATE
     AND v_computed_name IS NOT NULL
     AND v_existing_status IN ('Active', 'Inactive')   -- ← KEY GUARD (mig 464)
  THEN
    SELECT name INTO v_old_name FROM employees WHERE id = p_employee_id;
    IF v_old_name IS DISTINCT FROM v_computed_name THEN
      PERFORM set_config('prowess.allow_name_sync', 'true', true);
      UPDATE employees SET name = v_computed_name, updated_at = NOW()
      WHERE id = p_employee_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'case', v_case, 'personal_info_id', v_new_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL     ON FUNCTION upsert_personal_info(uuid, jsonb, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION upsert_personal_info(uuid, jsonb, date) TO authenticated;

COMMENT ON FUNCTION upsert_personal_info(uuid, jsonb, date) IS
  'Mig 454: full effective-dating rewrite. '
  'Mig 464: mirror guard — only syncs employees.name when status IN (Active, Inactive). '
  'During hire pipeline the satellite is sole source of truth for name. '
  'wf_activate_employee seeds employee_personal on activation if missing.';


-- =============================================================================
-- B. _sync_personal_info_today — add status guard
-- =============================================================================

CREATE OR REPLACE FUNCTION _sync_personal_info_today(
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows        integer := 0;
  v_errors      integer := 0;
  v_error_msgs  text    := NULL;
  r             RECORD;
BEGIN
  PERFORM set_config('prowess.allow_name_sync', 'true', true);

  FOR r IN
    SELECT ep.employee_id, ep.name
    FROM   employee_personal ep
    JOIN   employees e ON e.id = ep.employee_id
    WHERE  ep.effective_from <= p_as_of_date
      AND  ep.effective_to   >= p_as_of_date
      AND  ep.is_active       = true
      AND  e.deleted_at       IS NULL
      AND  e.status IN ('Active', 'Inactive')   -- ← KEY GUARD (mig 464)
      AND  e.name IS DISTINCT FROM ep.name
  LOOP
    BEGIN
      UPDATE employees
      SET    name       = r.name,
             updated_at = now()
      WHERE  id = r.employee_id;
      v_rows := v_rows + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors    := v_errors + 1;
      v_error_msgs := COALESCE(v_error_msgs, '') || r.employee_id::text || ': ' || SQLERRM || '; ';
    END;
  END LOOP;

  RETURN jsonb_build_object('rows', v_rows, 'error_count', v_errors, 'errors', v_error_msgs);
END;
$$;

COMMENT ON FUNCTION _sync_personal_info_today(date) IS
  'Internal helper: syncs employees.name from employee_personal for rows active on p_as_of_date. '
  'Called by activate_effective_dated_records(). '
  'Mig 353: initial. Mig 464: added status IN (Active, Inactive) guard — '
  'consistent with _sync_employment_today (459) and _sync_job_relationships_today (462).';

DO $$
BEGIN
  RAISE NOTICE 'Migration 464: personal info mirror and nightly sync now Active/Inactive only.';
END;
$$;
