-- =============================================================================
-- Migration 372 — Fix fn_close_and_replace_job_relationship_set: MAX(uuid)
--
-- mig 360 used MAX(CASE WHEN …) to pivot the 6 mirror columns, but PostgreSQL
-- has no MAX() aggregate for uuid. Replaced with LEFT JOINs — one per code.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_close_and_replace_job_relationship_set(
  p_employee_id    uuid,
  p_effective_from date,
  p_remove_codes   text[]    DEFAULT ARRAY[]::text[],
  p_new_items      jsonb     DEFAULT '[]'::jsonb,
  p_actor          uuid      DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_set    employee_job_relationship_set%ROWTYPE;
  v_new_set_id uuid;
  v_new_item   jsonb;
  v_mgr_id     uuid;
  v_code       text;
  v_pm01       uuid; v_pm02 uuid; v_pm03 uuid;
  v_om01       uuid; v_om02 uuid; v_om03 uuid;
BEGIN
  SELECT * INTO v_old_set
  FROM   employee_job_relationship_set
  WHERE  employee_id  = p_employee_id
    AND  is_active    = true
    AND  effective_to = '9999-12-31'::date
  FOR UPDATE;

  IF v_old_set.id IS NOT NULL THEN
    IF v_old_set.effective_from >= p_effective_from THEN
      DELETE FROM employee_job_relationship_set WHERE id = v_old_set.id;
    ELSE
      UPDATE employee_job_relationship_set
      SET    effective_to = p_effective_from - 1,
             is_active    = false,
             updated_by   = p_actor,
             updated_at   = NOW()
      WHERE  id = v_old_set.id;
    END IF;
  END IF;

  INSERT INTO employee_job_relationship_set
        (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
  VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
  RETURNING id INTO v_new_set_id;

  IF v_old_set.id IS NOT NULL THEN
    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
    SELECT v_new_set_id, relationship_code, manager_employee_id
    FROM   employee_job_relationship_item
    WHERE  set_id = v_old_set.id
      AND  relationship_code <> ALL(p_remove_codes)
    ON CONFLICT DO NOTHING;
  END IF;

  FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
  LOOP
    v_code   := v_new_item->>'relationship_code';
    v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
    VALUES (v_new_set_id, v_code, v_mgr_id)
    ON CONFLICT (set_id, relationship_code) DO UPDATE
      SET manager_employee_id = EXCLUDED.manager_employee_id;
  END LOOP;

  -- Mirror sync: LEFT JOINs per code (uuid has no MAX/MIN aggregate)
  IF p_effective_from <= CURRENT_DATE THEN
    SELECT
      pm01.manager_employee_id,
      pm02.manager_employee_id,
      pm03.manager_employee_id,
      om01.manager_employee_id,
      om02.manager_employee_id,
      om03.manager_employee_id
    INTO v_pm01, v_pm02, v_pm03, v_om01, v_om02, v_om03
    FROM (SELECT 1) dummy
    LEFT JOIN employee_job_relationship_item pm01 ON pm01.set_id = v_new_set_id AND pm01.relationship_code = 'PM01'
    LEFT JOIN employee_job_relationship_item pm02 ON pm02.set_id = v_new_set_id AND pm02.relationship_code = 'PM02'
    LEFT JOIN employee_job_relationship_item pm03 ON pm03.set_id = v_new_set_id AND pm03.relationship_code = 'PM03'
    LEFT JOIN employee_job_relationship_item om01 ON om01.set_id = v_new_set_id AND om01.relationship_code = 'OM01'
    LEFT JOIN employee_job_relationship_item om02 ON om02.set_id = v_new_set_id AND om02.relationship_code = 'OM02'
    LEFT JOIN employee_job_relationship_item om03 ON om03.set_id = v_new_set_id AND om03.relationship_code = 'OM03';

    PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

    UPDATE employees
    SET    pm01_manager_id = v_pm01,
           pm02_manager_id = v_pm02,
           pm03_manager_id = v_pm03,
           om01_manager_id = v_om01,
           om02_manager_id = v_om02,
           om03_manager_id = v_om03,
           updated_at      = NOW()
    WHERE  id = p_employee_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'set_id', v_new_set_id);
END;
$$;

COMMENT ON FUNCTION fn_close_and_replace_job_relationship_set(uuid, date, text[], jsonb, uuid) IS
  'Mig 372: fixed MAX(uuid) → LEFT JOIN per code. Closes current set, '
  'carries forward non-removed items, applies new items, syncs 6 mirror columns.';

SELECT proname FROM pg_proc WHERE proname = 'fn_close_and_replace_job_relationship_set';
