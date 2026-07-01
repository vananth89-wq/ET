-- =============================================================================
-- Migration 646 — delete_personal_info_record: delete-before-stitch
--
-- Bug: when deleting the "current" record (effective_to = '9999-12-31'), step 5
-- promoted prev to effective_to = '9999-12-31' while the target row was still
-- present → two rows matched idx_ep_one_active_row → unique constraint violated.
--
-- Fix: hard-delete the target row FIRST, then do the timeline-stitch UPDATEs.
-- Adjacent IDs and dates are captured before the delete so nothing is lost.
-- =============================================================================

CREATE OR REPLACE FUNCTION delete_personal_info_record(
  p_record_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec         employee_personal%ROWTYPE;
  v_prev_id     uuid;
  v_next_id     uuid;
  v_total       int;
BEGIN
  -- ── 1. Permission check ───────────────────────────────────────────────────
  IF NOT (user_can('personal_info', 'delete', p_employee_id) OR is_super_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Access denied: personal_info.delete required.');
  END IF;

  -- ── 2. Fetch the target record ────────────────────────────────────────────
  SELECT * INTO v_rec
  FROM   employee_personal
  WHERE  id          = p_record_id
    AND  employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Record not found.');
  END IF;

  -- ── 3. Guard: must keep at least one record ───────────────────────────────
  SELECT COUNT(*) INTO v_total
  FROM   employee_personal
  WHERE  employee_id = p_employee_id;

  IF v_total <= 1 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Cannot delete the only personal info record. At least one record must exist at all times.');
  END IF;

  -- ── 4. Locate adjacent records (before deleting) ─────────────────────────
  SELECT id INTO v_prev_id
  FROM   employee_personal
  WHERE  employee_id    = p_employee_id
    AND  effective_from < v_rec.effective_from
  ORDER  BY effective_from DESC
  LIMIT  1;

  SELECT id INTO v_next_id
  FROM   employee_personal
  WHERE  employee_id    = p_employee_id
    AND  effective_from > v_rec.effective_from
  ORDER  BY effective_from ASC
  LIMIT  1;

  -- ── 5. Hard-delete FIRST (clears the constraint before stitch) ───────────
  DELETE FROM employee_personal
  WHERE  id = p_record_id;

  -- ── 6. Re-stitch timeline ─────────────────────────────────────────────────
  IF v_prev_id IS NOT NULL THEN
    -- Prev absorbs this record's period (handles middle + current-record cases)
    UPDATE employee_personal
    SET    effective_to = v_rec.effective_to
    WHERE  id = v_prev_id;
  ELSIF v_next_id IS NOT NULL THEN
    -- No prev → deleting oldest; next extends back to fill the gap
    UPDATE employee_personal
    SET    effective_from = v_rec.effective_from
    WHERE  id = v_next_id;
  END IF;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_personal_info_record(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION delete_personal_info_record IS
  'Mig 639: delete-before-stitch to avoid idx_ep_one_active_row unique constraint '
  'violation when promoting prev row to effective_to = 9999-12-31.';
