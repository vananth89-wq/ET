-- =============================================================================
-- Migration 833 — Fix fn_close_and_replace_job_relationship_set: retroactive
--
-- BUG (mig 372 DELETE branch):
--   When the active set's effective_from >= p_effective_from, the function
--   deleted the active set (CASCADE-deleting all its items), then tried to
--   carry those items forward — getting nothing because they were already gone.
--
--   Two broken sub-cases:
--     A) active.effective_from > p_effective_from  (retroactive insert)
--        → items from the future set were lost; wrong items carried forward
--     B) active.effective_from = p_effective_from  (same-date update)
--        → all existing items were dropped, only new items survived
--
-- FIX — three cases instead of two:
--
--   CASE 1 (retroactive, >):
--     • Don't delete the active set.
--     • Shorten whatever closed set previously covered p_effective_from.
--     • Create a NEW CLOSED intermediate set from p_effective_from to
--       active.effective_from−1, carrying items from the previously-covering
--       set (not the future active set).
--     • Apply p_new_items and p_remove_codes to both the intermediate set
--       and the still-active set (because the new project/change is
--       ongoing past the active set's start).
--     • Sync mirrors from the active set (still authoritative).
--
--   CASE 2 (same date, =):
--     • Update items in-place on the existing active set.
--     • No delete, no new set.
--     • Sync mirrors.
--
--   CASE 3 (normal, <):
--     • Original logic unchanged: close old set, create new active set,
--       carry forward, apply new items, sync mirrors.
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
  v_old_set      employee_job_relationship_set%ROWTYPE;
  v_covering_set employee_job_relationship_set%ROWTYPE;
  v_new_set_id   uuid;
  v_new_item     jsonb;
  v_mgr_id       uuid;
  v_code         text;
  v_sync_id      uuid;   -- which set to read mirrors from
  v_pm01 uuid; v_pm02 uuid; v_pm03 uuid;
  v_om01 uuid; v_om02 uuid; v_om03 uuid;
BEGIN

  -- ── Lock the current active set ──────────────────────────────────────────
  SELECT * INTO v_old_set
  FROM   employee_job_relationship_set
  WHERE  employee_id  = p_employee_id
    AND  is_active    = true
    AND  effective_to = '9999-12-31'::date
  FOR UPDATE;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CASE 1 — retroactive: active set starts STRICTLY AFTER p_effective_from
  -- ═══════════════════════════════════════════════════════════════════════════
  IF v_old_set.id IS NOT NULL AND v_old_set.effective_from > p_effective_from THEN

    -- Find whichever closed set previously covered p_effective_from (may be none)
    SELECT * INTO v_covering_set
    FROM   employee_job_relationship_set
    WHERE  employee_id    = p_employee_id
      AND  is_active      = false
      AND  effective_from <= p_effective_from
      AND  effective_to   >= p_effective_from
    LIMIT 1;

    -- Shorten the covering set to end the day before p_effective_from
    IF v_covering_set.id IS NOT NULL THEN
      UPDATE employee_job_relationship_set
      SET    effective_to = p_effective_from - 1,
             updated_by   = p_actor,
             updated_at   = NOW()
      WHERE  id = v_covering_set.id;
    END IF;

    -- Create a new CLOSED intermediate set
    INSERT INTO employee_job_relationship_set
          (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id,
            p_effective_from,
            v_old_set.effective_from - 1,   -- ends day before active set starts
            false,
            p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

    -- Carry forward from the covering set (items that existed at p_effective_from)
    IF v_covering_set.id IS NOT NULL THEN
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      SELECT v_new_set_id, relationship_code, manager_employee_id
      FROM   employee_job_relationship_item
      WHERE  set_id = v_covering_set.id
        AND  relationship_code <> ALL(p_remove_codes)
      ON CONFLICT DO NOTHING;
    END IF;

    -- Apply new items to the intermediate set
    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_new_set_id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id;
    END LOOP;

    -- Also apply changes to the still-ACTIVE set (membership continues past its start)
    IF array_length(p_remove_codes, 1) > 0 THEN
      DELETE FROM employee_job_relationship_item
      WHERE  set_id = v_old_set.id
        AND  relationship_code = ANY(p_remove_codes);
    END IF;

    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_old_set.id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id;
    END LOOP;

    -- Mirrors come from the active set (it is still the authoritative state)
    v_sync_id := v_old_set.id;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CASE 2 — same date: active set starts on exactly p_effective_from
  -- ═══════════════════════════════════════════════════════════════════════════
  ELSIF v_old_set.id IS NOT NULL AND v_old_set.effective_from = p_effective_from THEN

    -- Update in place — no delete, no new set
    IF array_length(p_remove_codes, 1) > 0 THEN
      DELETE FROM employee_job_relationship_item
      WHERE  set_id = v_old_set.id
        AND  relationship_code = ANY(p_remove_codes);
    END IF;

    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_old_set.id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id;
    END LOOP;

    v_sync_id := v_old_set.id;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CASE 3 — normal: active set starts BEFORE p_effective_from (or no active set)
  -- ═══════════════════════════════════════════════════════════════════════════
  ELSE

    IF v_old_set.id IS NOT NULL THEN
      UPDATE employee_job_relationship_set
      SET    effective_to = p_effective_from - 1,
             is_active    = false,
             updated_by   = p_actor,
             updated_at   = NOW()
      WHERE  id = v_old_set.id;
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

    v_sync_id := v_new_set_id;

  END IF;

  -- ── Mirror sync (PM01–PM03, OM01–OM03 only — no mirror columns for PM04–PM06)
  -- Skip if the effective date for the new/updated set is in the future,
  -- meaning the current live state of mirrors should not change yet.
  -- For CASE 1 the active set is already in effect so we always sync.
  -- For CASE 2 the set is already active so we always sync.
  -- For CASE 3 only sync when p_effective_from <= today.
  IF v_sync_id IS NOT NULL
     AND (v_sync_id = v_old_set.id OR p_effective_from <= CURRENT_DATE)
  THEN
    SELECT
      pm01.manager_employee_id,
      pm02.manager_employee_id,
      pm03.manager_employee_id,
      om01.manager_employee_id,
      om02.manager_employee_id,
      om03.manager_employee_id
    INTO v_pm01, v_pm02, v_pm03, v_om01, v_om02, v_om03
    FROM  (SELECT 1) dummy
    LEFT JOIN employee_job_relationship_item pm01
           ON pm01.set_id = v_sync_id AND pm01.relationship_code = 'PM01'
    LEFT JOIN employee_job_relationship_item pm02
           ON pm02.set_id = v_sync_id AND pm02.relationship_code = 'PM02'
    LEFT JOIN employee_job_relationship_item pm03
           ON pm03.set_id = v_sync_id AND pm03.relationship_code = 'PM03'
    LEFT JOIN employee_job_relationship_item om01
           ON om01.set_id = v_sync_id AND om01.relationship_code = 'OM01'
    LEFT JOIN employee_job_relationship_item om02
           ON om02.set_id = v_sync_id AND om02.relationship_code = 'OM02'
    LEFT JOIN employee_job_relationship_item om03
           ON om03.set_id = v_sync_id AND om03.relationship_code = 'OM03';

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

    PERFORM set_config('prowess.allow_job_relationships_sync', 'false', true);
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'set_id', COALESCE(v_old_set.id, v_new_set_id)
  );

END;
$$;

COMMENT ON FUNCTION fn_close_and_replace_job_relationship_set(uuid, date, text[], jsonb, uuid) IS
  'Mig 833: three-case replace — CASE 1 retroactive (creates closed intermediate set, '
  'applies changes to still-active set); CASE 2 same-date (updates in-place, no delete); '
  'CASE 3 normal (closes old, creates new active). Fixes CASCADE-delete carry-forward bug.';

-- Verify the function exists with the new comment
SELECT obj_description(oid, 'pg_proc')
FROM   pg_proc
WHERE  proname = 'fn_close_and_replace_job_relationship_set';
