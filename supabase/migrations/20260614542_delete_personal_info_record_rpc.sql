-- =============================================================================
-- Migration 542 — delete_personal_info_record RPC
-- =============================================================================
--
-- Deletes one employee_personal row by its UUID, re-stitching the timeline
-- so there are no gaps.
--
-- Timeline stitch rules:
--   • Only record → BLOCKED (min 1 record; employee must always have coverage)
--   • Delete current (effective_to = '9999-12-31') AND prev exists:
--       UPDATE prev SET effective_to = '9999-12-31'   ← prev becomes current
--   • Delete oldest (no prev) AND next exists:
--       UPDATE next SET effective_from = deleted.effective_from
--   • Delete middle (prev AND next exist):
--       UPDATE prev SET effective_to = deleted.effective_to
--
-- Permission: user_can('personal_info', 'delete', p_employee_id)
-- Returns:    { ok: bool, error?: text }
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
  v_rec       employee_personal%ROWTYPE;
  v_prev_id   uuid;
  v_prev_from date;
  v_next_id   uuid;
  v_next_from date;
  v_total     int;
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
    RETURN jsonb_build_object('ok', false, 'error', 'Cannot delete the only personal info record. At least one record must exist at all times.');
  END IF;

  -- ── 4. Locate adjacent records ────────────────────────────────────────────
  -- Previous: latest record whose effective_from < this record's effective_from
  SELECT id, effective_from INTO v_prev_id, v_prev_from
  FROM   employee_personal
  WHERE  employee_id   = p_employee_id
    AND  effective_from < v_rec.effective_from
  ORDER  BY effective_from DESC
  LIMIT  1;

  -- Next: earliest record whose effective_from > this record's effective_from
  SELECT id, effective_from INTO v_next_id, v_next_from
  FROM   employee_personal
  WHERE  employee_id   = p_employee_id
    AND  effective_from > v_rec.effective_from
  ORDER  BY effective_from ASC
  LIMIT  1;

  -- ── 5. Re-stitch timeline ─────────────────────────────────────────────────
  IF v_prev_id IS NOT NULL THEN
    -- Prev absorbs this record's period (covers middle and current-record cases)
    UPDATE employee_personal
    SET    effective_to = v_rec.effective_to
    WHERE  id = v_prev_id;
  ELSIF v_next_id IS NOT NULL THEN
    -- No prev → deleting oldest record; next extends back to fill the gap
    UPDATE employee_personal
    SET    effective_from = v_rec.effective_from
    WHERE  id = v_next_id;
  END IF;
  -- (The only-record case is blocked above; no else branch needed)

  -- ── 6. Hard delete ────────────────────────────────────────────────────────
  DELETE FROM employee_personal
  WHERE  id = p_record_id;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_personal_info_record(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION delete_personal_info_record IS
  'Hard-deletes one employee_personal history record and re-stitches the timeline. Blocks if only one record remains. Migration 542.';

-- =============================================================================
-- END OF MIGRATION 542
-- =============================================================================
