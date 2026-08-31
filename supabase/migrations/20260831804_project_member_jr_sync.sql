-- =============================================================================
-- Migration : 20260831804_project_member_jr_sync.sql
-- Purpose   : Auto-sync Job Relationships when project members are added or
--             removed.
--
-- WHY SERVER-SIDE, NOT CLIENT-SIDE
--   upsert_job_relationship_set() has a dual path: HR/admin write directly
--   (PATH A), but any other caller (a project lead) goes to PATH B —
--   workflow staging — so the change sits pending and never appears. All
--   write code here calls fn_close_and_replace_job_relationship_set()
--   directly, which is SECURITY DEFINER and always PATH-A-equivalent.
--
-- WHAT HAPPENS
--   ADD : after a successful project_member_add(), the employee gets the next
--         free PM slot (PM01 … PM06) pointing to the project's manager_id.
--         If the manager is already in any PM slot for this employee, or all
--         six slots are taken, the call is a no-op.
--   REMOVE : when a project_member_remove() deletes or end-dates the row, the
--            PM slot that holds this project's manager is removed from the
--            employee's active JR set. If no slot matches, no-op.
--
-- HOW REMOVE IS TRIGGERED
--   project_member_remove() either DELETEs the row (no hours) or UPDATEs
--   effective_to to today (has hours). A trigger on project_members fires for
--   both cases and calls sync_project_jr_on_remove(). Patching the RPC itself
--   would have required tracking yet another text-replacement anchor through
--   a long chain of migrations.
--
-- FAILURE ISOLATION
--   Both helpers EXCEPTION WHEN OTHERS THEN NULL — a JR sync failure must
--   never roll back the member add/remove that triggered it.
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.  Helper: add one PM slot on project membership
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
  -- Which manager does this project report to?
  SELECT manager_id INTO v_manager_id FROM projects WHERE id = p_project_id;
  IF v_manager_id IS NULL THEN RETURN; END IF;

  -- Already there?  Nothing to do.
  IF EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id  = p_employee_id
      AND  s.is_active    = true
      AND  s.effective_to = '9999-12-31'::date
      AND  i.relationship_code   = ANY(v_pm_slots)
      AND  i.manager_employee_id = v_manager_id
  ) THEN RETURN; END IF;

  -- Find the first free PM slot.
  SELECT slot INTO v_slot
  FROM   unnest(v_pm_slots) AS slot
  WHERE  NOT EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id  = p_employee_id
      AND  s.is_active    = true
      AND  s.effective_to = '9999-12-31'::date
      AND  i.relationship_code = slot
  )
  LIMIT 1;

  IF v_slot IS NULL THEN RETURN; END IF;  -- all 6 PM slots full

  -- Carry all existing items forward and append the new slot.
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
    NULL   -- system (no human actor)
  );
EXCEPTION WHEN OTHERS THEN
  NULL;  -- best-effort; must not roll back the member add
END;
$$;

REVOKE ALL ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) TO authenticated;

COMMENT ON FUNCTION public.sync_project_jr_on_add(uuid, uuid, date) IS
  'Mig 804: called from project_member_add() after a successful INSERT. '
  'Finds the next free PM slot for the employee and points it at the '
  'project''s manager_id. No-op if already present or all slots are full.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.  Helper: remove the PM slot on membership end / delete
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_project_jr_on_remove(
  p_employee_id uuid,
  p_project_id  uuid
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

  IF v_slot IS NULL THEN RETURN; END IF;  -- nothing to remove

  -- Drop just that slot; carry everything else forward.
  PERFORM fn_close_and_replace_job_relationship_set(
    p_employee_id,
    CURRENT_DATE,
    ARRAY[v_slot],
    '[]'::jsonb,
    NULL
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.sync_project_jr_on_remove(uuid, uuid) IS
  'Mig 804: called from the project_members after-delete/update trigger. '
  'Finds the PM slot pointing at the project''s manager and removes it '
  'from the employee''s active JR set.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.  Patch project_member_add() to call sync_project_jr_on_add after INSERT
-- ─────────────────────────────────────────────────────────────────────────────
DO $patch$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
  -- Anchor: the RETURNING line that captures the new row id.
  -- It is unique in the function body and present since mig 774.
  a_ret text := E'  RETURNING id INTO v_id;';
  r_ret text := E'  RETURNING id INTO v_id;\n\n'
             || E'  -- Mig 804: sync job relationship\n'
             || E'  PERFORM sync_project_jr_on_add(p_employee_id, p_project_id, p_effective_from);\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'project_member_add';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'mig 804: project_member_add not found';
  END IF;

  IF position('sync_project_jr_on_add' IN v_src) > 0 THEN
    RAISE NOTICE 'mig 804: project_member_add already calls sync_project_jr_on_add — skipping';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a_ret, ''))) / NULLIF(length(a_ret), 0);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'mig 804: RETURNING anchor matched % times in project_member_add, expected 1', v_hits;
  END IF;

  v_new := replace(v_src, a_ret, r_ret);
  EXECUTE v_new;
END $patch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.  Trigger on project_members for the remove path
--     Fires AFTER DELETE (hard delete, no hours) and AFTER UPDATE OF
--     effective_to when the assignment is being ended today-or-earlier.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_pm_jr_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM sync_project_jr_on_remove(OLD.employee_id, OLD.project_id);
    RETURN OLD;
  END IF;

  -- UPDATE: only when effective_to is being set to today or earlier
  -- (project_member_remove path), not on ordinary date edits.
  IF TG_OP = 'UPDATE'
     AND (OLD.effective_to IS NULL OR OLD.effective_to > CURRENT_DATE)
     AND NEW.effective_to IS NOT NULL
     AND NEW.effective_to <= CURRENT_DATE THEN
    PERFORM sync_project_jr_on_remove(NEW.employee_id, NEW.project_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pm_jr_sync ON public.project_members;

CREATE TRIGGER trg_pm_jr_sync
AFTER DELETE OR UPDATE OF effective_to ON public.project_members
FOR EACH ROW EXECUTE FUNCTION public.trg_pm_jr_sync();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.  Verification
-- ─────────────────────────────────────────────────────────────────────────────
DO $verify$
BEGIN
  -- Helpers exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_add'
  ) THEN
    RAISE EXCEPTION 'mig 804: sync_project_jr_on_add is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'sync_project_jr_on_remove'
  ) THEN
    RAISE EXCEPTION 'mig 804: sync_project_jr_on_remove is missing';
  END IF;

  -- project_member_add calls the add helper
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'project_member_add'
      AND pg_get_functiondef(p.oid) LIKE '%sync_project_jr_on_add%'
  ) THEN
    RAISE EXCEPTION 'mig 804: project_member_add does not call sync_project_jr_on_add';
  END IF;

  -- Trigger exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'project_members'
      AND t.tgname = 'trg_pm_jr_sync'
  ) THEN
    RAISE EXCEPTION 'mig 804: trg_pm_jr_sync trigger is missing on project_members';
  END IF;

  RAISE NOTICE 'mig 804 verified: JR sync helpers present, project_member_add patched, trigger installed.';
END $verify$;

COMMIT;
