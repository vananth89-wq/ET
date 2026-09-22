-- =============================================================================
-- Migration 844 — a back-dated assignment reaches every month it covers
--
-- WHAT VJ FOUND
-- ═════════════
--   Add PM01 effective 01 Jul, then PM02 effective 01 Sep, then go back and add
--   PM03 effective 01 Jun. PM03 appears in June and in the current set, and is
--   absent from July -- a month it was in force for. Reproduced exactly on
--   PostgreSQL 16 against the live definition; the four rows it produces match
--   Dev row for row.
--
-- THREE DEFECTS, ALL IN CASE 1 (the retroactive branch)
-- ═════════════════════════════════════════════════════
--   1. IT WRITES TO TWO SETS AND SKIPS THE REST.
--      The new items go to the set it creates and to `v_old_set.id` -- the
--      ACTIVE set -- and to nothing in between. Every closed set between the
--      back-date and today is left untouched, so a snapshot that should carry
--      the assignment says the employee never had it.
--
--   2. IT BOUNDS THE NEW SET BY THE ACTIVE SET.
--      `v_old_set.effective_from - 1` ignores every set in between. Back-dating
--      to 20 Jun with sets at 01 Jul and 01 Sep produced 20 Jun - 31 Aug, which
--      OVERLAPS 01 Jul - 31 Aug outright. Two sets then claim July and August,
--      and "which set is in force on 15 July" has two answers. Dev has exactly
--      this pair today.
--
--   3. PICKING A DATE THAT ALREADY HAS A SET CRASHES.
--      The covering-set lookup used `effective_from <= p_effective_from`, so a
--      set starting ON that date matched, and was then truncated to
--      `p_effective_from - 1`: 01 Mar - 31 May became 01 Mar - 28 Feb. The user
--      got `chk_ejrs_effective_order` by name. Pre-existing -- the unmodified
--      835 function does it too -- and found only by testing for it.
--
-- THE RULE BEING RESTORED
-- ═══════════════════════
--   Each set is a COMPLETE SNAPSHOT from its effective_from; that is why CASE 3
--   carries the previous set's items forward when it creates one. An assignment
--   starting on p_effective_from therefore belongs in every later snapshot
--   until something says otherwise -- a set that fills the slot with a
--   different manager, or one where the code was soft-deleted. The fix walks
--   forward in date order and stops at the first of those.
--
-- WHY REMOVALS ARE NOT WALKED FORWARD
-- ═══════════════════════════════════
--   Because an ADD can be walked past an identical row safely: "carried
--   forward" and "entered deliberately" are indistinguishable in the data, and
--   for an add they mean the same thing. A REMOVE has no such luck -- a later
--   row naming the same manager might be the assignment continuing (should
--   end) or somebody re-entering it on purpose (must not), and ending it on a
--   guess silently deletes a real assignment. So a retroactive removal still
--   only touches the active set, exactly as before. Named, not forgotten.
--
-- AND A CONSTRAINT, BECAUSE A BRANCH IS NOT A RULE
-- ════════════════════════════════════════════════
--   Nothing in the database prevented the overlap in defect 2. The only index
--   on this table enforces ONE OPEN ACTIVE set; overlapping closed sets were
--   free. The function was the sole guard, and the function is what broke it.
--
--   This migration ABORTS if any employee already overlaps, and names them.
--   That is deliberate: a constraint added while the data contradicts it either
--   fails anyway or has to be weakened into something that never bites. Clear
--   the rows the abort names, then push again.
--
-- Depends on: 835 (the function this replaces, and removed_on),
--             359 (the schema and the one-active-set index),
--             829/833 (CASE 1's shape)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1 — refuse to proceed on data that already contradicts the rule
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s: %s..%s overlaps %s..%s',
                           COALESCE(e.name, a.employee_id::text),
                           a.effective_from, a.effective_to,
                           b.effective_from, b.effective_to), E'\n         ')
    INTO v_bad
  FROM   employee_job_relationship_set a
  JOIN   employee_job_relationship_set b
         ON  b.employee_id = a.employee_id
         AND b.id          > a.id
         AND daterange(a.effective_from, a.effective_to, '[]')
          && daterange(b.effective_from, b.effective_to, '[]')
  LEFT   JOIN employees e ON e.id = a.employee_id;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION E'MIG 844: job-relationship sets already overlap, so the constraint below cannot be created.\n         %\n         Delete these employees'' job relationship sets and re-enter them, then push again.', v_bad;
  END IF;
END $v$;

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE employee_job_relationship_set
  DROP CONSTRAINT IF EXISTS ejrs_no_overlap;

ALTER TABLE employee_job_relationship_set
  ADD CONSTRAINT ejrs_no_overlap
  EXCLUDE USING gist (employee_id WITH =,
                      daterange(effective_from, effective_to, '[]') WITH &&);

COMMENT ON CONSTRAINT ejrs_no_overlap ON employee_job_relationship_set IS
  'Mig 844: one set in force per employee per day. Closed sets were previously '
  'unconstrained, and a retroactive add bounded by the active set produced '
  'overlapping history that nothing objected to.';

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2 — the function
-- ═══════════════════════════════════════════════════════════════════════════
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
  v_next_from date;                                          -- MIG 844
  v_exact     employee_job_relationship_set%ROWTYPE;         -- MIG 844
  v_fwd       employee_job_relationship_set%ROWTYPE;         -- MIG 844
  v_fwd_item  employee_job_relationship_item%ROWTYPE;        -- MIG 844
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

    -- MIG 844: a set that starts on EXACTLY this date is not something to
    -- split -- it is the set being edited. The old lookup used
    -- effective_from <= p_effective_from, matched it, and then truncated it to
    -- p_effective_from - 1: a set running 01 Mar - 31 May became 01 Mar -
    -- 28 Feb and PostgreSQL rejected it with a raw
    -- chk_ejrs_effective_order violation. Picking the same date twice from the
    -- history panel was enough to hit it, and the user saw a constraint name.
    SELECT * INTO v_exact
    FROM   employee_job_relationship_set
    WHERE  employee_id    = p_employee_id
      AND  effective_from = p_effective_from
    LIMIT 1;

    IF v_exact.id IS NOT NULL THEN
      v_new_set_id := v_exact.id;
    ELSE
      -- Strictly BEFORE, so the exact-date case can never arrive here.
      SELECT * INTO v_covering_set
      FROM   employee_job_relationship_set
      WHERE  employee_id    = p_employee_id
        AND  is_active      = false
        AND  effective_from <  p_effective_from
        AND  effective_to   >= p_effective_from
      LIMIT 1;

      IF v_covering_set.id IS NOT NULL THEN
        UPDATE employee_job_relationship_set
        SET    effective_to = p_effective_from - 1,
               updated_by   = p_actor,
               updated_at   = NOW()
        WHERE  id = v_covering_set.id;
      END IF;
    END IF;

    -- MIG 844: bound by the NEXT set that starts after this date -- ANY set,
    -- not just the active one. The old code used v_old_set.effective_from - 1,
    -- which skips every set in between: back-dating to 20 Jun with sets at
    -- 01 Jul and 01 Sep produced 20 Jun - 31 Aug, overlapping 01 Jul - 31 Aug
    -- outright. Two sets then claim July and August and "which set is in force
    -- on 15 July" has two answers. There is always a later set here -- the
    -- active one qualifies -- so this is never NULL.
    IF v_exact.id IS NULL THEN
      SELECT min(effective_from) INTO v_next_from
      FROM   employee_job_relationship_set
      WHERE  employee_id    = p_employee_id
        AND  effective_from > p_effective_from;

      INSERT INTO employee_job_relationship_set
            (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
      VALUES (p_employee_id,
              p_effective_from,
              v_next_from - 1,
              false,
              p_actor, p_actor)
      RETURNING id INTO v_new_set_id;
    END IF;

    -- Carry forward from covering set (skip soft-deleted and removed codes)
    IF v_exact.id IS NULL AND v_covering_set.id IS NOT NULL THEN
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

    -- ═══ MIG 844: the assignment continues until something ends it ═══════
    -- The old code applied the new items to the new set and to the ACTIVE set,
    -- and to nothing in between. Back-dating PM03 to 01 Jun with sets at
    -- 01 Jul and 01 Sep put PM03 in June and September and left July saying the
    -- employee had no PM03 at all -- during a month in which they did.
    --
    -- Each set is a complete snapshot from its effective_from, so an assignment
    -- that starts on p_effective_from belongs in every later snapshot until
    -- something says otherwise. Two things say otherwise: a set that fills the
    -- same slot with a DIFFERENT manager (somebody took over from that date),
    -- and a set where the code is soft-deleted (it ended there). Walk forward
    -- in date order and stop at the first of those.
    --
    -- A set that already holds the same code with the SAME manager is walked
    -- PAST rather than stopped at: carried-forward and deliberately-entered are
    -- indistinguishable in the data, and here they have the same meaning, so it
    -- does not matter which it was.
    FOR v_new_item IN SELECT * FROM jsonb_array_elements(p_new_items)
    LOOP
      v_code   := v_new_item->>'relationship_code';
      v_mgr_id := (v_new_item->>'manager_employee_id')::uuid;

      FOR v_fwd IN
        SELECT *
        FROM   employee_job_relationship_set
        WHERE  employee_id    = p_employee_id
          AND  effective_from > p_effective_from
        ORDER  BY effective_from
      LOOP
        SELECT * INTO v_fwd_item
        FROM   employee_job_relationship_item
        WHERE  set_id = v_fwd.id AND relationship_code = v_code;

        IF FOUND THEN
          EXIT WHEN v_fwd_item.removed_on IS NOT NULL;
          EXIT WHEN v_fwd_item.manager_employee_id <> v_mgr_id;
          CONTINUE;
        END IF;

        INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
        VALUES (v_fwd.id, v_code, v_mgr_id);
      END LOOP;
    END LOOP;

    -- Removals are NOT walked forward, and that is deliberate rather than
    -- forgotten. Walking an ADD past an identical row is safe because both
    -- readings mean the same thing. A REMOVE has no such luck: a later row
    -- carrying the same manager might be the assignment continuing (should end)
    -- or somebody re-entering it on purpose (must not), and the data cannot
    -- tell them apart. Ending it on a guess would silently delete a real
    -- assignment, so a retroactive removal still only touches the active set,
    -- exactly as before.

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

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3 — verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe bigint;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the function is gone.';
  END IF;
  IF position('MIG 844' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the replacement did not land.';
  END IF;
  -- The three things this function must not have lost while being replaced.
  IF position('removed_on' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 844 FAILED: 835''s soft-delete handling was lost.';
  END IF;
  IF position('prowess.allow_job_relationships_sync' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the employees mirror sync was lost.';
  END IF;
  -- The new bound must be present...
  IF position('v_next_from - 1' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the retroactive set is not bounded by the next set.';
  END IF;
  -- ...and the old one gone. Matched as CODE, not as the bare name: the header
  -- above explains the old behaviour in prose and names the same expression, so
  -- a plain substring test finds this migration's own comment and fails a
  -- migration that applied perfectly. 839 lost a deploy to exactly that.
  IF v_src ~ 'p_effective_from,[[:space:]]*v_old_set\.effective_from - 1' THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the retroactive set is still bounded by the active set.';
  END IF;
  -- The forward walk itself, which is the whole point of the migration.
  IF position('effective_from > p_effective_from' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the forward walk is missing.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ejrs_no_overlap') THEN
    RAISE EXCEPTION 'MIG 844 FAILED: the overlap constraint was not created.';
  END IF;

  -- AW8: a plpgsql body is NOT parsed when the function is replaced, so a
  -- successful deploy says nothing about the statements just inserted. Run the
  -- forward walk's own query here against the real tables so every column it
  -- names has to resolve now rather than at the first person who back-dates.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set s
  WHERE  s.employee_id    = NULL::uuid
    AND  s.effective_from > NULL::date;

  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_item
  WHERE  set_id = NULL::uuid AND relationship_code = NULL::text
    AND  (removed_on IS NULL OR manager_employee_id IS NOT NULL);

  RAISE NOTICE 'MIG 844 OK: a back-dated assignment reaches every later set, and overlaps are now impossible.';
END $v$;

COMMIT;
