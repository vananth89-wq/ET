-- =============================================================================
-- Migration 835 — Soft-delete for employee_job_relationship_item
--
-- PROBLEM:
--   When fn_close_and_replace_job_relationship_set removes a PM/OM slot it
--   hard-deletes the row.  Two audit gaps result:
--
--   CASE 2 (in-place update on the active set):
--     The item simply vanishes.  No record that PM03=Divyasree existed in the
--     01 Aug set and was removed on 01 Aug.  The history panel shows only the
--     surviving slots with no indication of what changed.
--
--   CASE 3 (new set created):
--     Items not carried forward from the closing set disappear without a
--     "removed on" marker.  The set's effective_to gives the period, but not
--     which items were dropped and why.
--
-- FIX:
--   Add  removed_on date NULL  to employee_job_relationship_item.
--   All DELETE calls become  UPDATE … SET removed_on = p_effective_from.
--   All carry-forward, slot-finding, free-slot, and mirror-sync queries gain
--   AND removed_on IS NULL  so soft-deleted rows are invisible to logic.
--   ON CONFLICT clauses gain  removed_on = NULL  so re-adding a previously
--   removed slot in the same set correctly reactivates it.
--
-- WHAT THE UI CAN DO:
--   Show active items (removed_on IS NULL) normally.
--   Show soft-deleted items as struck-through with "removed dd Mon yyyy".
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.  Schema
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.employee_job_relationship_item
  ADD COLUMN IF NOT EXISTS removed_on date NULL;

COMMENT ON COLUMN public.employee_job_relationship_item.removed_on IS
  'Mig 835: soft-delete date — first date this PM/OM assignment is no longer '
  'valid within its set.  NULL = still active.  Set instead of hard-deleting '
  'so the UI can display full removal history.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.  fn_close_and_replace_job_relationship_set
--     Changes vs mig 833:
--       • DELETE → UPDATE SET removed_on   (CASE 1 active-set, CASE 2, CASE 3 audit)
--       • Carry-forward SELECTs: AND removed_on IS NULL
--       • ON CONFLICT: also SET removed_on = NULL  (re-activate if needed)
--       • Mirror-sync LEFT JOINs: AND <alias>.removed_on IS NULL
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_sync_id      uuid;
  v_pm01 uuid; v_pm02 uuid; v_pm03 uuid;
  v_om01 uuid; v_om02 uuid; v_om03 uuid;
BEGIN

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

    SELECT * INTO v_covering_set
    FROM   employee_job_relationship_set
    WHERE  employee_id    = p_employee_id
      AND  is_active      = false
      AND  effective_from <= p_effective_from
      AND  effective_to   >= p_effective_from
    LIMIT 1;

    IF v_covering_set.id IS NOT NULL THEN
      UPDATE employee_job_relationship_set
      SET    effective_to = p_effective_from - 1,
             updated_by   = p_actor,
             updated_at   = NOW()
      WHERE  id = v_covering_set.id;
    END IF;

    INSERT INTO employee_job_relationship_set
          (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id,
            p_effective_from,
            v_old_set.effective_from - 1,
            false,
            p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

    -- Carry forward from covering set (skip soft-deleted and removed codes)
    IF v_covering_set.id IS NOT NULL THEN
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      SELECT v_new_set_id, relationship_code, manager_employee_id
      FROM   employee_job_relationship_item
      WHERE  set_id            = v_covering_set.id
        AND  removed_on        IS NULL
        AND  relationship_code <> ALL(p_remove_codes)
      ON CONFLICT DO NOTHING;
    END IF;

    -- Apply new items to intermediate set (re-activate if previously removed)
    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_new_set_id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id,
            removed_on          = NULL;
    END LOOP;

    -- Apply remove_codes to the still-active set: soft-delete instead of hard-delete
    IF array_length(p_remove_codes, 1) > 0 THEN
      UPDATE employee_job_relationship_item
      SET    removed_on = p_effective_from
      WHERE  set_id            = v_old_set.id
        AND  relationship_code = ANY(p_remove_codes)
        AND  removed_on        IS NULL;
    END IF;

    -- Apply new items to the still-active set (re-activate if previously removed)
    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_old_set.id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id,
            removed_on          = NULL;
    END LOOP;

    v_sync_id := v_old_set.id;

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CASE 2 — same date: active set starts on exactly p_effective_from
  -- ═══════════════════════════════════════════════════════════════════════════
  ELSIF v_old_set.id IS NOT NULL AND v_old_set.effective_from = p_effective_from THEN

    -- Soft-delete removed slots — records when the assignment ended in this set
    IF array_length(p_remove_codes, 1) > 0 THEN
      UPDATE employee_job_relationship_item
      SET    removed_on = p_effective_from
      WHERE  set_id            = v_old_set.id
        AND  relationship_code = ANY(p_remove_codes)
        AND  removed_on        IS NULL;
    END IF;

    -- Apply new items (re-activate if the slot was previously soft-deleted)
    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      VALUES (v_old_set.id, v_code, v_mgr_id)
      ON CONFLICT (set_id, relationship_code) DO UPDATE
        SET manager_employee_id = EXCLUDED.manager_employee_id,
            removed_on          = NULL;
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

      -- Soft-delete removed slots in the closing set:
      -- audit trail for why the new set does not carry them forward
      IF array_length(p_remove_codes, 1) > 0 THEN
        UPDATE employee_job_relationship_item
        SET    removed_on = p_effective_from
        WHERE  set_id            = v_old_set.id
          AND  relationship_code = ANY(p_remove_codes)
          AND  removed_on        IS NULL;
      END IF;
    END IF;

    INSERT INTO employee_job_relationship_set
          (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

    -- Carry forward (skip soft-deleted items and explicitly removed codes)
    IF v_old_set.id IS NOT NULL THEN
      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
      SELECT v_new_set_id, relationship_code, manager_employee_id
      FROM   employee_job_relationship_item
      WHERE  set_id            = v_old_set.id
        AND  removed_on        IS NULL
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
        SET manager_employee_id = EXCLUDED.manager_employee_id,
            removed_on          = NULL;
    END LOOP;

    v_sync_id := v_new_set_id;

  END IF;

  -- ── Mirror sync — AND <alias>.removed_on IS NULL so soft-deleted slots ────
  -- ── are not counted as active managers                                  ────
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
          AND pm01.removed_on IS NULL
    LEFT JOIN employee_job_relationship_item pm02
           ON pm02.set_id = v_sync_id AND pm02.relationship_code = 'PM02'
          AND pm02.removed_on IS NULL
    LEFT JOIN employee_job_relationship_item pm03
           ON pm03.set_id = v_sync_id AND pm03.relationship_code = 'PM03'
          AND pm03.removed_on IS NULL
    LEFT JOIN employee_job_relationship_item om01
           ON om01.set_id = v_sync_id AND om01.relationship_code = 'OM01'
          AND om01.removed_on IS NULL
    LEFT JOIN employee_job_relationship_item om02
           ON om02.set_id = v_sync_id AND om02.relationship_code = 'OM02'
          AND om02.removed_on IS NULL
    LEFT JOIN employee_job_relationship_item om03
           ON om03.set_id = v_sync_id AND om03.relationship_code = 'OM03'
          AND om03.removed_on IS NULL;

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
  'Mig 835: soft-delete (removed_on) instead of hard-delete for removed PM/OM slots. '
  'All carry-forward and slot queries filter removed_on IS NULL. '
  'Mirror sync LEFT JOINs filter removed_on IS NULL. '
  'ON CONFLICT clauses set removed_on = NULL to re-activate a previously removed slot. '
  'CASE 3 closing set: soft-deletes removed codes as an audit trail.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.  sync_project_jr_on_add — filter removed_on IS NULL
--     • "Already there?" guard must ignore soft-deleted assignments
--     • "Find first free slot" must ignore soft-deleted occupants
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_project_jr_on_add(
  p_employee_id    uuid,
  p_project_id     uuid,
  p_effective_from date
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_manager_id uuid;
  v_pm_slots   text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_slot       text;
BEGIN
  SELECT manager_id INTO v_manager_id FROM projects WHERE id = p_project_id;
  IF v_manager_id IS NULL THEN RETURN; END IF;

  -- Already there? (ignore soft-deleted assignments — a removed slot is free)
  IF EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id           = p_employee_id
      AND  s.is_active             = true
      AND  s.effective_to          = '9999-12-31'::date
      AND  i.relationship_code     = ANY(v_pm_slots)
      AND  i.manager_employee_id   = v_manager_id
      AND  i.removed_on            IS NULL
  ) THEN RETURN; END IF;

  -- Find the first free PM slot (soft-deleted occupants count as free)
  SELECT slot INTO v_slot
  FROM   unnest(v_pm_slots) AS slot
  WHERE  NOT EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id       = p_employee_id
      AND  s.is_active         = true
      AND  s.effective_to      = '9999-12-31'::date
      AND  i.relationship_code = slot
      AND  i.removed_on        IS NULL
  )
  LIMIT 1;

  IF v_slot IS NULL THEN RETURN; END IF;

  PERFORM fn_close_and_replace_job_relationship_set(
    p_employee_id,
    p_effective_from,
    ARRAY[]::text[],
    jsonb_build_array(
      jsonb_build_object(
        'relationship_code',   v_slot,
        'manager_employee_id', v_manager_id::text
      )
    ),
    NULL
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) TO authenticated;

COMMENT ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) IS
  'Mig 835: "already there" guard and free-slot search both filter '
  'removed_on IS NULL — soft-deleted assignments are invisible to add logic '
  'so a removed slot can be reused or reassigned.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.  sync_project_jr_on_remove (mig 834) — filter removed_on IS NULL
--     Slot-finding query must not match an already-soft-deleted slot
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_project_jr_on_remove(
  p_employee_id  uuid,
  p_project_id   uuid,
  p_removal_date date DEFAULT CURRENT_DATE
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_manager_id uuid;
  v_pm_slots   text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_slot       text;
BEGIN
  SELECT manager_id INTO v_manager_id FROM projects WHERE id = p_project_id;
  IF v_manager_id IS NULL THEN RETURN; END IF;

  -- Shared-manager guard (mig 834): another active project with the same manager
  -- still covers this employee as of p_removal_date — keep the slot
  IF EXISTS (
    SELECT 1
    FROM   project_members pm
    JOIN   projects        p  ON p.id = pm.project_id
    WHERE  pm.employee_id   = p_employee_id
      AND  p.manager_id     = v_manager_id
      AND  pm.project_id    <> p_project_id
      AND  pm.effective_from <= p_removal_date
      AND  (pm.effective_to IS NULL OR pm.effective_to >= p_removal_date)
  ) THEN
    RETURN;
  END IF;

  -- Which PM slot holds this manager? (ignore soft-deleted slots)
  SELECT i.relationship_code INTO v_slot
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  s.employee_id         = p_employee_id
    AND  s.is_active           = true
    AND  s.effective_to        = '9999-12-31'::date
    AND  i.relationship_code   = ANY(v_pm_slots)
    AND  i.manager_employee_id = v_manager_id
    AND  i.removed_on          IS NULL
  LIMIT 1;

  IF v_slot IS NULL THEN RETURN; END IF;

  PERFORM fn_close_and_replace_job_relationship_set(
    p_employee_id,
    p_removal_date,
    ARRAY[v_slot],
    '[]'::jsonb,
    NULL
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid, date) TO authenticated;

COMMENT ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid, date) IS
  'Mig 835: slot-finding query filters removed_on IS NULL — already-soft-deleted '
  'slots are not re-processed. Inherits mig 834 past-date accuracy and '
  'shared-manager guard unchanged.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.  Verification
-- ─────────────────────────────────────────────────────────────────────────────
DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'employee_job_relationship_item'
      AND column_name  = 'removed_on'
  ) THEN
    RAISE EXCEPTION 'mig 835: removed_on column missing from employee_job_relationship_item';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'fn_close_and_replace_job_relationship_set'
      AND pg_get_functiondef(p.oid) LIKE '%removed_on%'
  ) THEN
    RAISE EXCEPTION 'mig 835: fn_close_and_replace_job_relationship_set does not reference removed_on';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_add'
      AND pg_get_functiondef(p.oid) LIKE '%removed_on%'
  ) THEN
    RAISE EXCEPTION 'mig 835: sync_project_jr_on_add does not reference removed_on';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_remove'
      AND pg_get_functiondef(p.oid) LIKE '%removed_on%'
  ) THEN
    RAISE EXCEPTION 'mig 835: sync_project_jr_on_remove does not reference removed_on';
  END IF;

  RAISE NOTICE 'mig 835 verified: removed_on column present, fn_close_and_replace + both sync helpers updated.';
END $verify$;

COMMIT;
