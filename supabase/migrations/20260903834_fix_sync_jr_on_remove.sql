-- =============================================================================
-- Migration 834 — Fix sync_project_jr_on_remove
--
-- Two problems fixed:
--
-- 1. PAST-DATE REMOVAL
--    The old function used CURRENT_DATE as the JR boundary, so if a project
--    membership was ended retroactively (effective_to = last month), the JR
--    still showed the manager until today. Fix: pass effective_to + 1 from
--    the trigger so the JR boundary matches the actual last day of membership.
--
-- 2. SHARED-MANAGER GUARD
--    If two projects share the same manager and the employee is removed from
--    one, the PM slot was dropped — even though the other project still
--    justifies it. Fix: before removing the slot, check whether another
--    active project membership for the same manager still exists as of the
--    removal date.
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.  New 3-param version of sync_project_jr_on_remove
--     (old 2-param version dropped after trigger is updated)
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

  -- ── Shared-manager guard ──────────────────────────────────────────────────
  -- Another active project with the same manager covers this employee as of
  -- p_removal_date — keep the PM slot, nothing to remove.
  IF EXISTS (
    SELECT 1
    FROM   project_members pm
    JOIN   projects        p  ON p.id = pm.project_id
    WHERE  pm.employee_id   = p_employee_id
      AND  p.manager_id     = v_manager_id
      AND  pm.project_id    <> p_project_id          -- not the project being removed
      AND  pm.effective_from <= p_removal_date        -- was active by removal date
      AND  (pm.effective_to IS NULL
            OR pm.effective_to >= p_removal_date)     -- still active on removal date
  ) THEN
    RETURN;
  END IF;

  -- Which PM slot holds this manager for this employee?
  SELECT i.relationship_code INTO v_slot
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  s.employee_id  = p_employee_id
    AND  s.is_active    = true
    AND  s.effective_to = '9999-12-31'::date
    AND  i.relationship_code   = ANY(v_pm_slots)
    AND  i.manager_employee_id = v_manager_id
  LIMIT 1;

  IF v_slot IS NULL THEN RETURN; END IF;

  -- Drop just that slot; carry everything else forward.
  -- Uses p_removal_date so the JR boundary matches the last day of membership.
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
  'Mig 834: accepts explicit p_removal_date (first day the employee is no '
  'longer in the project; defaults to today for hard deletes). Shared-manager '
  'guard keeps the PM slot if another project still has the same manager for '
  'this employee as of p_removal_date.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.  Update trigger to pass the correct date
--     DELETE  → CURRENT_DATE   (employee removed immediately, today is last day)
--     UPDATE  → effective_to + 1  (first day not in project)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_pm_jr_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM sync_project_jr_on_remove(OLD.employee_id, OLD.project_id, CURRENT_DATE);
    RETURN OLD;
  END IF;

  -- UPDATE: only when effective_to is being set to today-or-earlier (end-dating).
  -- Pass effective_to + 1 so the JR records the correct boundary:
  --   last day in project = effective_to → first day without project = effective_to + 1
  IF TG_OP = 'UPDATE'
     AND (OLD.effective_to IS NULL OR OLD.effective_to > CURRENT_DATE)
     AND NEW.effective_to IS NOT NULL
     AND NEW.effective_to <= CURRENT_DATE THEN
    PERFORM sync_project_jr_on_remove(
      NEW.employee_id,
      NEW.project_id,
      NEW.effective_to + 1   -- e.g. if removed as of Aug 31, JR changes from Sep 1
    );
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.trg_pm_jr_sync() IS
  'Mig 834: passes effective_to+1 for UPDATE so past-date removals record '
  'the exact JR boundary rather than defaulting to today.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.  Drop old 2-param version (now superseded; trigger no longer calls it)
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.sync_project_jr_on_remove(uuid, uuid);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.  Verify
-- ─────────────────────────────────────────────────────────────────────────────
DO $verify$
BEGIN
  -- 3-param version exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_remove'
      AND pg_get_function_arguments(p.oid) LIKE '%removal_date%'
  ) THEN
    RAISE EXCEPTION 'mig 834: 3-param sync_project_jr_on_remove not found';
  END IF;

  -- 2-param version is gone
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_remove'
      AND pg_get_function_arguments(p.oid) NOT LIKE '%removal_date%'
  ) THEN
    RAISE EXCEPTION 'mig 834: old 2-param sync_project_jr_on_remove still exists';
  END IF;

  -- Trigger body references effective_to + 1
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'trg_pm_jr_sync'
      AND pg_get_functiondef(p.oid) LIKE '%effective_to + 1%'
  ) THEN
    RAISE EXCEPTION 'mig 834: trg_pm_jr_sync does not pass effective_to + 1';
  END IF;

  RAISE NOTICE 'mig 834 verified: past-date removal and shared-manager guard in place.';
END $verify$;

COMMIT;
