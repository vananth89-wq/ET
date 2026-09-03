-- =============================================================================
-- Migration 831: Admin Edit / Delete for historical Job Relationship sets
--
-- Adds two SECURITY DEFINER RPCs callable only by users with the respective
-- job_relationships permission:
--
--   admin_update_job_relationship_set(p_set_id, p_items)
--     • Replaces all items in ANY set (active or historical).
--     • For the active set, also re-syncs pm01–om03 mirror columns on employees.
--     • Requires: job_relationships.edit
--
--   admin_delete_job_relationship_set(p_set_id)
--     • Permanently deletes a HISTORICAL (non-active) set and its items.
--     • Active sets cannot be deleted this way (use upsert_job_relationship_set).
--     • Requires: job_relationships.delete
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. admin_update_job_relationship_set
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_update_job_relationship_set(
  p_set_id uuid,
  p_items  jsonb   -- [{relationship_code text, manager_employee_id uuid}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_employee_id uuid;
  v_is_active   boolean;
BEGIN
  -- Permission gate
  IF NOT user_can('job_relationships', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied');
  END IF;

  -- Fetch the target set
  SELECT employee_id, is_active
  INTO   v_employee_id, v_is_active
  FROM   employee_job_relationship_set
  WHERE  id = p_set_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Set not found');
  END IF;

  -- Replace items atomically
  DELETE FROM employee_job_relationship_item WHERE set_id = p_set_id;

  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
  SELECT
    p_set_id,
    elem->>'relationship_code',
    (elem->>'manager_employee_id')::uuid
  FROM jsonb_array_elements(p_items) AS elem
  WHERE (elem->>'manager_employee_id') IS NOT NULL
    AND (elem->>'manager_employee_id') <> '';

  -- Re-sync mirror columns when the active set is touched
  IF v_is_active THEN
    PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

    UPDATE employees SET
      pm01_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM01' LIMIT 1),
      pm02_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM02' LIMIT 1),
      pm03_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM03' LIMIT 1),
      om01_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM01' LIMIT 1),
      om02_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM02' LIMIT 1),
      om03_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM03' LIMIT 1)
    WHERE id = v_employee_id;

    PERFORM set_config('prowess.allow_job_relationships_sync', 'false', true);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_update_job_relationship_set(uuid, jsonb) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. admin_delete_job_relationship_set
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_delete_job_relationship_set(
  p_set_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_active boolean;
BEGIN
  -- Permission gate
  IF NOT user_can('job_relationships', 'delete', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied');
  END IF;

  SELECT is_active
  INTO   v_is_active
  FROM   employee_job_relationship_set
  WHERE  id = p_set_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Set not found');
  END IF;

  -- Active sets must not be deleted via this path
  IF v_is_active THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Cannot delete the active set. Use the Edit button to change it instead.'
    );
  END IF;

  DELETE FROM employee_job_relationship_item WHERE set_id = p_set_id;
  DELETE FROM employee_job_relationship_set   WHERE id    = p_set_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_job_relationship_set(uuid) TO authenticated;
