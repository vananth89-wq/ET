-- =============================================================================
-- Migration 543 — delete_employment_record RPC
-- =============================================================================
--
-- Deletes one employee_employment row by UUID, re-stitching the timeline.
-- Identical stitch logic to delete_personal_info_record (mig 542).
--
-- Extra step when deleting the CURRENT record (effective_to = '9999-12-31'):
--   After stitching, the new current record (prev) must be synced back to the
--   employees mirror columns (designation, job_title, dept_id, manager_id,
--   hire_date, work_country, work_location, base_currency_id).
--   This keeps the employees table consistent with upsert_employment_info.
--
-- Permission: user_can('employment', 'delete', p_employee_id)
-- Returns:    { ok: bool, error?: text }
-- =============================================================================

CREATE OR REPLACE FUNCTION delete_employment_record(
  p_record_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec         employee_employment%ROWTYPE;
  v_prev_id     uuid;
  v_next_id     uuid;
  v_total       int;
  v_is_current  boolean;
  v_new_current employee_employment%ROWTYPE;
BEGIN
  -- ── 1. Permission check ───────────────────────────────────────────────────
  IF NOT (user_can('employment', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: employment.delete required.');
  END IF;

  -- ── 2. Fetch target record ────────────────────────────────────────────────
  SELECT * INTO v_rec
  FROM   employee_employment
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Record not found.');
  END IF;

  v_is_current := (v_rec.effective_to = '9999-12-31'::date);

  -- ── 3. Guard: min 1 record ────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_total
  FROM   employee_employment
  WHERE  employee_id = p_employee_id;

  IF v_total <= 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Cannot delete the only employment record. At least one record must exist at all times.');
  END IF;

  -- ── 4. Adjacent records ───────────────────────────────────────────────────
  SELECT id INTO v_prev_id
  FROM   employee_employment
  WHERE  employee_id    = p_employee_id
    AND  effective_from < v_rec.effective_from
  ORDER  BY effective_from DESC
  LIMIT  1;

  SELECT id INTO v_next_id
  FROM   employee_employment
  WHERE  employee_id    = p_employee_id
    AND  effective_from > v_rec.effective_from
  ORDER  BY effective_from ASC
  LIMIT  1;

  -- ── 5. Re-stitch ──────────────────────────────────────────────────────────
  IF v_prev_id IS NOT NULL THEN
    UPDATE employee_employment
    SET    effective_to = v_rec.effective_to
    WHERE  id = v_prev_id;
  ELSIF v_next_id IS NOT NULL THEN
    UPDATE employee_employment
    SET    effective_from = v_rec.effective_from
    WHERE  id = v_next_id;
  END IF;

  -- ── 6. Hard delete ────────────────────────────────────────────────────────
  DELETE FROM employee_employment WHERE id = p_record_id;

  -- ── 7. Mirror sync — only needed when current record was deleted ──────────
  --
  -- After deleting the current row the prev (now open-ended) becomes the new
  -- current. Sync its values back to employees so the mirror stays consistent.
  IF v_is_current THEN
    SELECT * INTO v_new_current
    FROM   employee_employment
    WHERE  employee_id  = p_employee_id
      AND  effective_to = '9999-12-31'::date
    LIMIT  1;

    IF FOUND THEN
      UPDATE employees
      SET
        designation      = v_new_current.designation,
        job_title        = v_new_current.job_title,
        dept_id          = v_new_current.dept_id,
        manager_id       = v_new_current.manager_id,
        hire_date        = v_new_current.hire_date,
        work_country     = v_new_current.work_country,
        work_location    = v_new_current.work_location,
        base_currency_id = v_new_current.base_currency_id,
        updated_at       = now()
      WHERE id = p_employee_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_employment_record(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION delete_employment_record IS
  'Hard-deletes one employee_employment history record, re-stitches the timeline, and syncs the employees mirror when the current record is removed. Blocks if only one record remains. Migration 543.';

-- =============================================================================
-- END OF MIGRATION 543
-- =============================================================================
