-- =============================================================================
-- Migration : 20260420007_picklist_value_delete_fn.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Adds SECURITY DEFINER RPCs for insert/delete on picklist_values.
--              Both functions enforce lock_timeout = 5s so the client never
--              hangs forever when an idle transaction holds table locks.
--              Admin role is checked inside each function.
-- =============================================================================

-- ── DELETE ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION delete_picklist_values(p_ids UUID[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET lock_timeout = '5s'
AS $$
BEGIN
  IF NOT has_role('admin') THEN
    RAISE EXCEPTION 'Permission denied: admin role required';
  END IF;

  DELETE FROM picklist_values WHERE id = ANY(p_ids);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_picklist_values(UUID[]) TO authenticated;


-- ── INSERT ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION insert_picklist_value(
  p_picklist_id     UUID,
  p_value           TEXT,
  p_parent_value_id UUID    DEFAULT NULL,
  p_ref_id          TEXT    DEFAULT NULL,
  p_meta            JSONB   DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET lock_timeout = '5s'
AS $$
DECLARE
  v_new_id UUID;
BEGIN
  IF NOT has_role('admin') THEN
    RAISE EXCEPTION 'Permission denied: admin role required';
  END IF;

  INSERT INTO picklist_values (picklist_id, value, parent_value_id, ref_id, active, meta)
  VALUES (p_picklist_id, p_value, p_parent_value_id, p_ref_id, true, p_meta)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION insert_picklist_value(UUID, TEXT, UUID, TEXT, JSONB) TO authenticated;

-- =============================================================================
-- END OF MIGRATION 20260420007_picklist_value_delete_fn.sql
-- =============================================================================
