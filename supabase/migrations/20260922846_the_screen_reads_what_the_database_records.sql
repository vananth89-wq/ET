-- =============================================================================
-- Migration 846 — the Job Relationships screen reads what the database records
--
-- THE REPORT
-- ══════════
--   Delimit a project assignment to 31 Aug. The database does exactly the right
--   thing: PM05 gets `removed_on = 2026-09-01` in the current set. The screen
--   shows PM05 exactly as before, so it reads as "nothing happened".
--
--   `removed_on` appears in ZERO client files and in exactly one migration
--   besides the one that added it. Both RPCs this screen calls were last
--   written by migration 360 -- five months before 835 added the column.
--   835 wrote down what was missing and it was never built:
--
--       "Show active items (removed_on IS NULL) normally. Show soft-deleted
--        items as struck-through with 'removed dd Mon yyyy'."
--
--   Meanwhile employees.pmNN_manager_id IS correct, because 835's mirror does
--   filter. So the database holds two answers to "who is her PM05", and which
--   one you get depends on which reader you ask. That is 840's dead column
--   again: one fact, two homes, only one kept in step.
--
-- WHAT "REMOVED" MEANS, AND WHY ONE FILTER WILL NOT DO
-- ════════════════════════════════════════════════════
--   `removed_on` is the first date the assignment is no longer valid WITHIN ITS
--   SET. So PM05 carrying removed_on = 01 Sep:
--
--     * in the ACTIVE set (01 Sep -> 9999) it is invalid for the whole set;
--     * in the JULY set (01 Jul - 31 Aug) it was valid throughout.
--
--   The blunt `removed_on IS NULL` -- which 835 uses, correctly, where it only
--   ever meets the active set -- hides it from July too, and July then says she
--   had no PM05 during a month she did. That is the same defect as the one this
--   thread started from, arriving from the other side. So:
--
--     current  ->  removed_on IS NULL OR removed_on > CURRENT_DATE
--     history  ->  removed_on IS NULL OR removed_on > s.effective_from
--
--   and history RETURNS removed_on, so an item that ended mid-set can be shown
--   struck through rather than silently dropped.
--
-- AND "CURRENT" BECOMES A DATE, NOT A FLAG
-- ════════════════════════════════════════
--   get_current_job_relationships picked its set with
--   `is_active = true AND effective_to = '9999-12-31'`. That is "the open-ended
--   set", not "the set in force today", and the two differ the moment anything
--   is dated ahead. Measured on PostgreSQL 16, with a future-dated set made the
--   ordinary way through the portlet:
--
--       today 2026-09-22
--       by is_active + 9999 : 2027-03-01 .. 9999-12-31   <- what it returned
--       in force by date    : 2026-09-01 .. 2027-02-28   <- what it should
--
--   An HR user who post-dates a change sees it take effect immediately, months
--   early. Nothing prevents them: 456 validates against the hire date, not the
--   future. This is live today and is not caused by any change of ours.
--
-- AND AN EDIT STOPS RESURRECTING THE DEAD
-- ═══════════════════════════════════════
--   admin_update_job_relationship_set deletes every item and re-inserts from a
--   payload that has never heard of removed_on, so any Edit on any set wipes
--   every removal marker on it -- and because history currently returns removed
--   items as live, the edit form re-submits them and they come back with
--   removed_on NULL. One Edit and an ended relationship is live again, with
--   nothing recording that it ever ended. It now carries removal markers across
--   the rebuild, for slots whose manager it is not changing.
--
-- NOT IN THIS MIGRATION, deliberately, each for its own reason:
--   * _bulk_export_job_relationships, fn_queue_job_relationship_notifications
--     and both submit_change_request overloads -- same filter, different
--     readers, and each needs its own test. 847.
--   * fn_apply_job_relationship_set_transition -- needs the removal-marker fix
--     AND 844's forward walk, which it never got. 847.
--   * The mirror columns are still a cached copy of a fact the item table holds.
--     Vj has chosen that a future-dated end takes effect on the day, applied by
--     a daily job. That job, and the trigger change it needs, are 848.
--
-- Depends on: 360 (the two RPCs), 835 (removed_on), 844 (the timeline these read)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. get_current_job_relationships — by date, and without ended assignments
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_current_job_relationships(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_set    employee_job_relationship_set%ROWTYPE;
  v_items  jsonb;
BEGIN
  IF NOT user_can('job_relationships', 'view', p_employee_id)
    AND NOT user_can('job_relationships', 'view', NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- MIG 846: the set IN FORCE TODAY, by date. It used to be chosen by the
  -- active flag together with the 9999 sentinel, which is a different question
  -- -- that returns the open-ended set, and a post-dated change makes the
  -- open-ended set one that has not started yet. ORDER BY covers the
  -- overlapping history 844's constraint now forbids but older rows may still
  -- carry: prefer the latest start.
  --
  -- (The old predicate is described rather than quoted on purpose. The
  -- verification below asserts it is gone, and a comment containing it makes
  -- that assertion fire on a migration that applied perfectly -- which is
  -- exactly how 839 and 844 each lost a deploy.)
  SELECT * INTO v_set
  FROM   employee_job_relationship_set
  WHERE  employee_id = p_employee_id
    AND  CURRENT_DATE BETWEEN effective_from AND effective_to
  ORDER  BY effective_from DESC
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'set', NULL, 'items', '[]'::jsonb);
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                   i.id,
      'relationship_code',    i.relationship_code,
      'manager_employee_id',  i.manager_employee_id,
      'manager_name',         e.name,
      'manager_employee_code', e.employee_id,
      'created_at',           i.created_at
    ) ORDER BY pv.ref_id
  ) INTO v_items
  FROM   employee_job_relationship_item i
  JOIN   employees e  ON e.id = i.manager_employee_id
  LEFT JOIN picklist_values pv
    ON pv.ref_id = i.relationship_code
   AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
  WHERE  i.set_id = v_set.id
    -- MIG 846: an assignment ended on or before today is not a current
    -- manager. One ending in the future still is, until that day.
    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE);

  RETURN jsonb_build_object(
    'ok',   true,
    'set',  jsonb_build_object(
              'id',             v_set.id,
              'effective_from', v_set.effective_from,
              'effective_to',   v_set.effective_to,
              'is_active',      v_set.is_active,
              'created_at',     v_set.created_at
            ),
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. get_job_relationships_history — per set, and it says what ended
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_job_relationships_history(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sets jsonb;
BEGIN
  IF NOT user_can('job_relationships', 'history', p_employee_id)
    AND NOT user_can('job_relationships', 'view',    p_employee_id)
    AND NOT user_can('job_relationships', 'history', NULL)
    AND NOT user_can('job_relationships', 'view',    NULL)
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id',             s.id,
      'effective_from', s.effective_from,
      'effective_to',   s.effective_to,
      'is_active',      s.is_active,
      'created_at',     s.created_at,
      'items', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id',                  i.id,
            'relationship_code',   i.relationship_code,
            'manager_employee_id', i.manager_employee_id,
            'manager_name',        e.name,
            'manager_employee_code', e.employee_id,
            -- MIG 846: returned so the panel can print "removed 15 Aug" on an
            -- assignment that ended DURING this set, instead of dropping it and
            -- leaving the reader to wonder where it went.
            'removed_on',          i.removed_on
          ) ORDER BY pv.ref_id
        )
        FROM   employee_job_relationship_item i
        JOIN   employees e ON e.id = i.manager_employee_id
        LEFT JOIN picklist_values pv
          ON pv.ref_id = i.relationship_code
         AND pv.picklist_id = (SELECT id FROM picklists WHERE picklist_id = 'JOB_RELATIONSHIP_TYPE')
        WHERE  i.set_id = s.id
          -- MIG 846: compared against THIS SET's start, not against today. An
          -- item ended 01 Sep was valid for every day of a 01 Jul - 31 Aug set
          -- and belongs in it; it is not part of a set beginning 01 Sep.
          AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from)
      )
    )
    ORDER BY s.effective_from DESC
  ) INTO v_sets
  FROM employee_job_relationship_set s
  WHERE s.employee_id = p_employee_id;

  RETURN jsonb_build_object(
    'ok',   true,
    'sets', COALESCE(v_sets, '[]'::jsonb)
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. admin_update_job_relationship_set — an edit no longer erases a removal
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_update_job_relationship_set(p_set_id uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_employee_id uuid;
  v_is_active   boolean;
BEGIN
  IF NOT user_can('job_relationships', 'edit', NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Permission denied');
  END IF;

  SELECT employee_id, is_active
  INTO   v_employee_id, v_is_active
  FROM   employee_job_relationship_set
  WHERE  id = p_set_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Set not found');
  END IF;

  -- MIG 846: remember what had already ended, before the rebuild throws it away.
  CREATE TEMP TABLE _mig846_prior ON COMMIT DROP AS
  SELECT relationship_code, manager_employee_id, removed_on
  FROM   employee_job_relationship_item
  WHERE  set_id = p_set_id AND removed_on IS NOT NULL;

  DELETE FROM employee_job_relationship_item WHERE set_id = p_set_id;

  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
  SELECT
    p_set_id,
    elem->>'relationship_code',
    (elem->>'manager_employee_id')::uuid
  FROM jsonb_array_elements(p_items) AS elem
  WHERE (elem->>'manager_employee_id') IS NOT NULL
    AND (elem->>'manager_employee_id') <> '';

  -- MIG 846: put the removal markers back.
  --
  -- ONLY where the manager is unchanged. If this edit put somebody ELSE in the
  -- slot it is a new assignment and the old one's end date says nothing about
  -- it; carrying the marker over would mark the new manager as already gone.
  --
  -- This matters because the edit form cannot see removed items -- nothing in
  -- the client knows the column exists -- so it submits the set without them
  -- and, before this, an Edit silently brought an ended relationship back to
  -- life with no record that it had ever ended.
  UPDATE employee_job_relationship_item i
  SET    removed_on = p.removed_on
  FROM   _mig846_prior p
  WHERE  i.set_id              = p_set_id
    AND  i.relationship_code   = p.relationship_code
    AND  i.manager_employee_id = p.manager_employee_id;

  -- A slot that was ended and is absent from the payload is restored as the
  -- ended row it was, rather than vanishing: the audit 835 built is the point.
  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on)
  SELECT p_set_id, p.relationship_code, p.manager_employee_id, p.removed_on
  FROM   _mig846_prior p
  WHERE  NOT EXISTS (
    SELECT 1 FROM employee_job_relationship_item i
    WHERE  i.set_id = p_set_id AND i.relationship_code = p.relationship_code);

  IF v_is_active THEN
    PERFORM set_config('prowess.allow_job_relationships_sync', 'true', true);

    -- MIG 846: the mirror is what the org chart reads. An ended assignment is
    -- not a current manager, so the same date rule applies here.
    UPDATE employees SET
      pm01_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM01' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1),
      pm02_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM02' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1),
      pm03_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'PM03' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1),
      om01_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM01' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1),
      om02_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM02' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1),
      om03_manager_id = (SELECT manager_employee_id FROM employee_job_relationship_item WHERE set_id = p_set_id AND relationship_code = 'OM03' AND (removed_on IS NULL OR removed_on > CURRENT_DATE) LIMIT 1)
    WHERE id = v_employee_id;

    PERFORM set_config('prowess.allow_job_relationships_sync', 'false', true);
  END IF;

  DROP TABLE IF EXISTS _mig846_prior;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_fn text; v_probe bigint;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['get_current_job_relationships',
                              'get_job_relationships_history',
                              'admin_update_job_relationship_set']
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'MIG 846 FAILED: %() is missing.', v_fn;
    END IF;
    IF position('MIG 846' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 846 FAILED: %() did not take the replacement.', v_fn;
    END IF;
    IF position('removed_on' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 846 FAILED: %() still does not mention removed_on.', v_fn;
    END IF;
    -- Every one of these must still refuse the wrong caller. A migration about
    -- display that quietly widens access is worse than the bug it fixes.
    IF position('user_can' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 846 FAILED: %() lost its permission gate.', v_fn;
    END IF;
  END LOOP;

  -- The flag test must be gone from the current reader, and only from it:
  -- history is ABOUT every set, and the bulk export is 847's.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'get_current_job_relationships';
  -- Matched as CODE -- `AND` then the flag -- not as the bare phrase, so prose
  -- describing the old behaviour cannot trip it.
  IF v_src ~ 'AND[[:space:]]+is_active[[:space:]]*=[[:space:]]*true' THEN
    RAISE EXCEPTION 'MIG 846 FAILED: get_current_job_relationships still picks its set by the is_active flag.';
  END IF;
  IF position('CURRENT_DATE BETWEEN effective_from AND effective_to' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 846 FAILED: get_current_job_relationships does not select by date.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the new predicate against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  CURRENT_DATE BETWEEN s.effective_from AND s.effective_to
    AND  (i.removed_on IS NULL OR i.removed_on > CURRENT_DATE)
    AND  (i.removed_on IS NULL OR i.removed_on > s.effective_from);

  RAISE NOTICE 'MIG 846 OK: current is a date, history says what ended, and an edit keeps the record of it.';
END $v$;

COMMIT;
