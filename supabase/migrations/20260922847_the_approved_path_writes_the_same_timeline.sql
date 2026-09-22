-- =============================================================================
-- Migration 847 — the approved path writes the same timeline as the direct one
--
-- TWO WRITERS, ONE JOB, DIFFERENT RULES
-- ═════════════════════════════════════
--   A job relationship change can be written two ways:
--
--     fn_close_and_replace_job_relationship_set   direct HR edit   (fixed: 844)
--     fn_apply_job_relationship_set_transition    workflow APPROVED (this one)
--
--   They have separate case logic and only the first got 844's forward walk.
--   So the bug Vj reported -- back-date an assignment and it is missing from
--   every later month -- is still live on the approval route. Measured on
--   PostgreSQL 16 against the definition read from Dev: approving a change
--   effective 01 Jun, with sets at 01 Jul and 01 Sep, put PM03 in June and
--   nowhere else.
--
--   This migration gives the prepend and split cases the same forward walk, for
--   the same reasons: an assignment starting on p_effective_from belongs in
--   every later set until something says otherwise -- a set filling the slot
--   with a DIFFERENT manager, or one where the code was soft-deleted.
--   Corrections and amendments are excluded: a correction rewrites one set in
--   place and says nothing about later ones; an amendment opens the newest set,
--   so there is nothing after it to reach.
--
-- AND A CORRECTION STOPS ERASING THE AUDIT
-- ════════════════════════════════════════
--   The correction case deletes every item and re-inserts from the payload --
--   and the payload has never heard of removed_on, because nothing in the
--   client knows the column exists. 846 repaired exactly this in
--   admin_update_job_relationship_set; this is the other rebuild path. Without
--   it, approving a correction wipes every removal marker on the set and brings
--   ended relationships back to life with nothing recording that they ended.
--
-- WHY THIS IS URGENT NOW AND WAS NOT LAST WEEK
-- ════════════════════════════════════════════
--   Until 845, this function raised on every call -- it invoked a mirror helper
--   that did not exist -- and a failed approval writes nothing. The outage was
--   accidentally protecting the data. 845 unbroke the path, so it is newly
--   usable and newly able to corrupt a timeline.
--
-- DELIBERATELY NOT HERE, while Prowess is still in testing and nothing acts on
-- the output: _bulk_export_job_relationships, fn_queue_job_relationship_
-- notifications, and both submit_change_request overloads all still read ended
-- relationships as live. Those produce wrong DISPLAY. This migration is the
-- part that writes wrong DATA.
--
-- Depends on: 454/456 (this function), 835 (removed_on), 844 (the rule),
--             845 (the mirror helper it calls), 846 (the same repair, other path)
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_apply_job_relationship_set_transition(p_employee_id uuid, p_effective_from date, p_items jsonb, p_actor uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_case          text;
  v_target_id     uuid;
  v_target_eff_from date;
  v_inherited_end date;
  v_new_set_id    uuid;
  v_item          jsonb;
  v_manager_id    uuid;
  v_fwd           employee_job_relationship_set%ROWTYPE;   -- MIG 847
  v_fwd_item      employee_job_relationship_item%ROWTYPE;  -- MIG 847
  v_code          text;                                    -- MIG 847
BEGIN
  -- ── Case detection ─────────────────────────────────────────────────────────
  SELECT id INTO v_target_id FROM employee_job_relationship_set
  WHERE employee_id = p_employee_id AND effective_from = p_effective_from LIMIT 1;
  IF FOUND THEN v_case := 'correction'; END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id ORDER BY effective_from ASC LIMIT 1;
    IF FOUND AND p_effective_from < v_target_eff_from THEN
      v_case := 'prepend'; v_inherited_end := v_target_eff_from - 1;
    END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_to INTO v_target_id, v_inherited_end
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND effective_from < p_effective_from
      AND effective_to  != '9999-12-31'::date
      AND effective_to  >= p_effective_from
    ORDER BY effective_from DESC LIMIT 1;
    IF FOUND THEN v_case := 'split'; END IF;
  END IF;

  IF v_case IS NULL THEN
    SELECT id, effective_from INTO v_target_id, v_target_eff_from
    FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id
      AND is_active = true AND effective_to = '9999-12-31'::date LIMIT 1;
    v_case := 'amendment'; v_inherited_end := '9999-12-31'::date;
  END IF;

  -- ── Execute by case ────────────────────────────────────────────────────────
  IF v_case = 'correction' THEN
    -- MIG 847: remember what had already ENDED before the rebuild discards it.
    -- 846 made this same repair to admin_update_job_relationship_set; this is
    -- the other path that rebuilds a set from a payload, and the payload has
    -- never heard of removed_on. Without this, approving any correction wipes
    -- every removal marker on the set and brings ended relationships back to
    -- life with no record that they ever ended.
    CREATE TEMP TABLE _mig847_prior ON COMMIT DROP AS
    SELECT relationship_code, manager_employee_id, removed_on
    FROM   employee_job_relationship_item
    WHERE  set_id = v_target_id AND removed_on IS NOT NULL;

    DELETE FROM employee_job_relationship_item WHERE set_id = v_target_id;
    v_new_set_id := v_target_id;

  ELSIF v_case = 'prepend' THEN
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSIF v_case = 'split' THEN
    UPDATE employee_job_relationship_set
    SET effective_to = p_effective_from - 1, is_active = false,
        updated_at = NOW(), updated_by = p_actor
    WHERE id = v_target_id;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, v_inherited_end, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;

  ELSE -- amendment / gap_fill
    IF v_target_id IS NOT NULL THEN
      IF v_target_eff_from >= p_effective_from THEN
        DELETE FROM employee_job_relationship_set WHERE id = v_target_id;
      ELSE
        UPDATE employee_job_relationship_set
        SET effective_to = p_effective_from - 1, is_active = false,
            updated_at = NOW(), updated_by = p_actor
        WHERE id = v_target_id;
      END IF;
    END IF;
    INSERT INTO employee_job_relationship_set
      (employee_id, effective_from, effective_to, is_active, created_by, updated_by)
    VALUES (p_employee_id, p_effective_from, '9999-12-31'::date, true, p_actor, p_actor)
    RETURNING id INTO v_new_set_id;
  END IF;

  -- ── Insert items ───────────────────────────────────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id INTO v_manager_id FROM employees
    WHERE employee_id = v_item->>'manager_employee_id';

    IF v_manager_id IS NULL THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: manager % not found',
        v_item->>'manager_employee_id';
    END IF;

    IF v_manager_id = p_employee_id THEN
      RAISE EXCEPTION 'fn_apply_job_relationship_set_transition: self-assignment not allowed';
    END IF;

    INSERT INTO employee_job_relationship_item (
      set_id, relationship_code, manager_employee_id
    ) VALUES (
      v_new_set_id,
      v_item->>'relationship_code',
      v_manager_id
    );
  END LOOP;

  -- ── MIG 847: restore removal markers after a correction rebuild ───────────
  -- Only where the manager is unchanged: a different manager in the slot is a
  -- new assignment and must not inherit somebody else's end date. A slot that
  -- was ended and is absent from the payload comes back as the ended row it
  -- was, because the audit is the point.
  IF v_case = 'correction' THEN
    UPDATE employee_job_relationship_item i
    SET    removed_on = p.removed_on
    FROM   _mig847_prior p
    WHERE  i.set_id              = v_new_set_id
      AND  i.relationship_code   = p.relationship_code
      AND  i.manager_employee_id = p.manager_employee_id;

    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, removed_on)
    SELECT v_new_set_id, p.relationship_code, p.manager_employee_id, p.removed_on
    FROM   _mig847_prior p
    WHERE  NOT EXISTS (
      SELECT 1 FROM employee_job_relationship_item i
      WHERE  i.set_id = v_new_set_id AND i.relationship_code = p.relationship_code);

    DROP TABLE IF EXISTS _mig847_prior;
  END IF;

  -- ── MIG 847: a back-dated approval reaches every month it covers ──────────
  -- 844 fixed this in fn_close_and_replace_job_relationship_set, the DIRECT HR
  -- edit. This is the other writer -- the workflow-APPROVED path -- and it
  -- never got the fix. Its prepend and split cases create a back-dated set and
  -- touch nothing after it, so an approved change effective 01 Jun lands in
  -- June and is missing from July, exactly the defect 844 was written for.
  --
  -- Same rule, same reasons: an assignment that starts on p_effective_from
  -- belongs in every later set until something says otherwise -- a set filling
  -- the slot with a DIFFERENT manager, or one where the code was soft-deleted.
  -- A set already holding the same code with the SAME manager is walked past:
  -- carried-forward and deliberately-entered are indistinguishable here and
  -- mean the same thing.
  --
  -- Corrections and amendments are excluded. A correction rewrites one set in
  -- place and says nothing about later ones; an amendment opens the newest set,
  -- so there is nothing after it to reach.
  IF v_case IN ('prepend', 'split') THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_code := v_item->>'relationship_code';
      SELECT id INTO v_manager_id FROM employees
      WHERE employee_id = v_item->>'manager_employee_id';
      CONTINUE WHEN v_manager_id IS NULL;

      FOR v_fwd IN
        SELECT * FROM employee_job_relationship_set
        WHERE  employee_id    = p_employee_id
          AND  effective_from > p_effective_from
        ORDER  BY effective_from
      LOOP
        SELECT * INTO v_fwd_item
        FROM   employee_job_relationship_item
        WHERE  set_id = v_fwd.id AND relationship_code = v_code;

        IF FOUND THEN
          EXIT WHEN v_fwd_item.removed_on IS NOT NULL;
          EXIT WHEN v_fwd_item.manager_employee_id <> v_manager_id;
          CONTINUE;
        END IF;

        INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)
        VALUES (v_fwd.id, v_code, v_manager_id);
      END LOOP;
    END LOOP;
  END IF;

  -- ── Mirror sync — only if most-recent set ─────────────────────────────────
  IF p_effective_from <= CURRENT_DATE AND NOT EXISTS (
    SELECT 1 FROM employee_job_relationship_set
    WHERE employee_id = p_employee_id AND effective_from > p_effective_from
  ) THEN
    PERFORM sync_job_relationship_mirrors(p_employee_id, v_new_set_id);
  END IF;

  RETURN v_new_set_id;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE v_src text; v_probe bigint;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_apply_job_relationship_set_transition';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the function is gone.';
  END IF;
  IF position('MIG 847' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the replacement did not land.';
  END IF;

  -- The forward walk, matched as CODE. A negative or positive assertion that
  -- matches prose fires on a migration that applied perfectly -- 839, 844 and
  -- 846 each lost a run to exactly that, so this names a predicate, not a word.
  IF v_src !~ 'effective_from[[:space:]]*>[[:space:]]*p_effective_from' THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the forward walk is not in the function.';
  END IF;
  IF position('_mig847_prior' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the correction case does not preserve removal markers.';
  END IF;

  -- What must survive being replaced.
  IF position('sync_job_relationship_mirrors' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the mirror sync was lost.';
  END IF;
  IF position('self-assignment not allowed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 847 FAILED: the self-assignment guard was lost.';
  END IF;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- walk's own predicate against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  s.employee_id = NULL::uuid
    AND  s.effective_from > NULL::date
    AND  (i.removed_on IS NULL OR i.manager_employee_id IS NOT NULL);

  RAISE NOTICE 'MIG 847 OK: an approved back-date reaches every later set, and a correction keeps its removal markers.';
END $v$;

COMMIT;
