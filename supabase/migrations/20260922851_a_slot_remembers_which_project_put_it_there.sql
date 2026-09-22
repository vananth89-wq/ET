-- =============================================================================
-- Migration 851 — a slot remembers which project put it there
--
-- THE REPORT
-- ══════════
--   "When project manager changes in between, the job relationship assignment
--    to employees should be adjusted accordingly."
--
--   Today nothing happens. `Admin -> Projects` writes UPDATE projects SET
--   manager_id, one trigger fires (797) and notifies people, and job
--   relationships are not touched by anything. sync_project_jr_on_add only
--   ever runs when a MEMBERSHIP is created: it reads projects.manager_id at
--   that instant and copies the value into a PM slot. A snapshot, taken once,
--   never revisited. Change the lead and every member keeps the old one in
--   their slot for good, while the new lead appears in nobody's -- and
--   wf_subject_employee_approver_type routes approvals off that.
--
-- WHY IT COULD NOT BE FIXED BEFORE
-- ════════════════════════════════
--   A PM slot holds a manager id and NOTHING recording why. It might have been
--   written by sync_project_jr_on_add because of project X, or set by hand by
--   HR for a reason the system knows nothing about. So "whose slots do I
--   rewrite when X changes hands" had no safe answer: matching on the manager
--   catches the deliberate ones too, and rewriting those silently destroys a
--   decision somebody made. 844 wrote this down as the reason a removal is not
--   walked forward; G1 is the same wall from the other side -- the nightly job
--   can end a slot but can never add one, because it does not know which slots
--   are its own.
--
--   This migration gives the row the missing fact.
--
--       employee_job_relationship_item.source_project_id uuid NULL
--
--   NULL means a human put it there and automation never touches it. Non-NULL
--   means the slot exists because of that project.
--
-- NO BACKFILL, AND THAT IS THE SAFE DIRECTION
-- ═══════════════════════════════════════════
--   Vj's call, and it happens to be the conservative one. Every existing row
--   reads as NULL, so this migration cannot move a single slot that is already
--   out there: the new behaviour begins with memberships created after it. A
--   backfill would have had to GUESS which existing slots were project-derived
--   -- the guess this whole column exists to avoid -- and a wrong guess
--   rewrites HR's deliberate assignments. Not backfilling is not a shortcut
--   here; it is the only way to be sure.
--
-- WHAT ELSE THE COLUMN FIXES ON ARRIVAL
-- ═════════════════════════════════════
--   sync_project_jr_on_remove finds the slot to release by looking up
--   projects.manager_id TODAY and matching it. After a lead change that column
--   holds the NEW lead, so ending a membership releases the wrong person's
--   slot, or silently finds nothing. With provenance it asks the slot which
--   project owns it and matches on that, falling back to the old lookup for
--   NULL rows.
--
--   Both sync functions also selected the employee's picture with
--   `is_active = true AND effective_to = '9999-12-31'` -- the flag test 846
--   removed from the readers and left here (G3). With anything post-dated,
--   these consulted a picture that has not started yet and could take a slot
--   that is not free today. They are rewritten here anyway, so they select by
--   date; leaving a predicate known to be wrong inside a body being replaced
--   is not a saving.
--
--   And both ended `EXCEPTION WHEN OTHERS THEN NULL`. A sync that fails now
--   raises a WARNING. 845 was three months of a function that could not run,
--   found only because something finally called it.
--
-- WHAT IT DOES NOT DO
-- ═══════════════════
--   The change takes effect the day it is saved. projects.manager_id is one
--   scalar with no history, so "from 01 Oct" still means "change it on 01 Oct".
--   Effective-dating the project lead is a separate table and a separate
--   migration; Vj chose to stop here for now.
--
--   One slot, one owner. If the same person leads two of an employee's
--   projects they occupy one slot owned by whichever project filled it first;
--   when that project changes hands the shared-manager guard hands ownership
--   to the other project and leaves the assignment alone. Correct, but it
--   cannot show that two projects justify the same slot.
--
-- Depends on: 834 (the shared-manager rule), 844 (the writer), 850 (the record
--             day a removal now gets), 797 (which already watches manager_id)
-- =============================================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The column
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.employee_job_relationship_item
  ADD COLUMN IF NOT EXISTS source_project_id uuid;

DO $mig$
BEGIN
  -- ON DELETE SET NULL, not CASCADE. Deleting a project must not delete
  -- somebody's manager: the slot simply stops being owned and becomes
  -- hands-off, which is exactly what an unowned slot means everywhere else.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conname = 'ejri_source_project_fkey'
      AND  conrelid = 'public.employee_job_relationship_item'::regclass
  ) THEN
    ALTER TABLE public.employee_job_relationship_item
      ADD CONSTRAINT ejri_source_project_fkey
      FOREIGN KEY (source_project_id) REFERENCES public.projects(id)
      ON DELETE SET NULL;
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS idx_ejri_source_project
  ON public.employee_job_relationship_item (source_project_id)
  WHERE source_project_id IS NOT NULL;

COMMENT ON COLUMN public.employee_job_relationship_item.source_project_id IS
  'MIG 851: the project that put this manager in this slot, or NULL when a '
  'human did. Automation may only move a slot it owns. Never backfilled: every '
  'row that predates this column reads as hand-set and is left alone forever.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Provenance survives a new set
-- ═══════════════════════════════════════════════════════════════════════════
--   Each set is a fresh snapshot and carry-forward rebuilds the rows, so
--   without this the column would be correct exactly until the next unrelated
--   edit and then silently empty. The two carry-forward blocks copy it; the
--   three explicit-assignment blocks CLEAR it, because somebody naming a
--   manager for a slot is the definition of a hand-set one -- and the project
--   paths re-stamp immediately afterwards, so they are unaffected.
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_from text;
  v_to   text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_close_and_replace_job_relationship_set';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 851 FAILED: fn_close_and_replace_job_relationship_set() does not exist.';
  END IF;
  -- The prerequisite is the record day, not a marker. 849 shipped under two
  -- different contents and its marker means nothing; 850 is what actually
  -- gives the writer its pre-pass, whichever file a database got it from.
  IF position('fn_jr_open_removal_record' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 851 FAILED: the writer has no record-day pre-pass -- 850 has not been applied.';
  END IF;

  IF position('source_project_id' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 851: the writer already carries provenance -- skipping.';
  ELSE

    -- ── 2a. carry-forward, CASE 1 (from the covering set) ────────────────────
    v_from := '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_covering_set.id';
    v_to   := '      -- MIG 851: source_project_id travels with the slot.' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_covering_set.id';

    v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 851 FAILED: expected 1 CASE 1 carry-forward, found %.', v_hits;
    END IF;
    v_new := replace(v_src, v_from, v_to);

    -- ── 2b. carry-forward, CASE 3 (from the closing set) ─────────────────────
    v_from := '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id';
    v_to   := '      -- MIG 851: source_project_id travels with the slot.' || E'\n'
           || '      INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '      SELECT v_new_set_id, relationship_code, manager_employee_id, source_project_id' || E'\n'
           || '      FROM   employee_job_relationship_item' || E'\n'
           || '      WHERE  set_id            = v_old_set.id';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 851 FAILED: expected 1 CASE 3 carry-forward, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    -- ── 2c. an explicit assignment clears ownership (3 sites, 2 identical) ───
    v_from := '      ON CONFLICT (set_id, relationship_code) DO UPDATE' || E'\n'
           || '        SET manager_employee_id = EXCLUDED.manager_employee_id,' || E'\n'
           || '            removed_on          = NULL;';
    v_to   := '      ON CONFLICT (set_id, relationship_code) DO UPDATE' || E'\n'
           || '        SET manager_employee_id = EXCLUDED.manager_employee_id,' || E'\n'
           || '            removed_on          = NULL,' || E'\n'
           || '            source_project_id   = NULL;   -- MIG 851: named, so hand-set';

    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 3 THEN
      RAISE EXCEPTION 'MIG 851 FAILED: expected 3 explicit-assignment blocks, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 851: fn_close_and_replace_job_relationship_set carries provenance.';
  END IF;
END $mig$;

-- 849's record day clones the live items of the set it splits: same rule.
DO $mig$
DECLARE
  v_src text; v_new text; v_from text; v_to text; v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'fn_jr_open_removal_record';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 851 FAILED: fn_jr_open_removal_record() is missing -- 850 not applied.';
  END IF;

  IF position('source_project_id' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 851: the record-day helper already carries provenance -- skipping.';
  ELSE
    -- Two clone sites, at different indentation: the gap branch (four spaces)
    -- and the split branch (two). Patched separately so each hit is asserted
    -- on its own rather than one count covering both.
    v_new := v_src;

    v_from := '    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)' || E'\n'
           || '    SELECT v_id, relationship_code, manager_employee_id';
    v_to   := '    -- MIG 851: provenance travels with the slot.' || E'\n'
           || '    INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '    SELECT v_id, relationship_code, manager_employee_id, source_project_id';
    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 851 FAILED: expected 1 gap-branch clone, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    v_from := E'\n' || '  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id)' || E'\n'
           || '  SELECT v_id, relationship_code, manager_employee_id';
    v_to   := E'\n' || '  -- MIG 851: provenance travels with the slot.' || E'\n'
           || '  INSERT INTO employee_job_relationship_item (set_id, relationship_code, manager_employee_id, source_project_id)' || E'\n'
           || '  SELECT v_id, relationship_code, manager_employee_id, source_project_id';
    v_hits := (length(v_new) - length(replace(v_new, v_from, ''))) / length(v_from);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 851 FAILED: expected 1 split-branch clone, found %.', v_hits;
    END IF;
    v_new := replace(v_new, v_from, v_to);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 851: fn_jr_open_removal_record carries provenance.';
  END IF;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Stamping a slot as a project's own
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_jr_stamp_slot_source(
  p_employee_id uuid,
  p_slot        text,
  p_manager_id  uuid,
  p_from        date,
  p_project_id  uuid
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Every set from p_from onward that holds this manager in this slot. The
  -- forward walk 844 added can place the same assignment in several later
  -- sets in one call, and each of them is the same project's doing.
  --
  -- `source_project_id IS NULL` is a refusal to steal: a slot another project
  -- already owns keeps its owner, so the first project to fill a slot keeps it
  -- and the shared-manager guard decides the rest.
  UPDATE employee_job_relationship_item i
  SET    source_project_id = p_project_id
  FROM   employee_job_relationship_set s
  WHERE  s.id                 = i.set_id
    AND  s.employee_id        = p_employee_id
    AND  s.effective_to      >= p_from
    AND  i.relationship_code  = p_slot
    AND  i.manager_employee_id = p_manager_id
    AND  i.removed_on         IS NULL
    AND  i.source_project_id  IS NULL;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. The add path stamps what it creates
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sync_project_jr_on_add(
  p_employee_id uuid, p_project_id uuid, p_effective_from date
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_manager_id uuid;
  v_pm_slots   text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_slot       text;
BEGIN
  SELECT manager_id INTO v_manager_id FROM projects WHERE id = p_project_id;
  IF v_manager_id IS NULL THEN RETURN; END IF;

  -- MIG 851: the picture IN FORCE on the date this takes effect. This used to
  -- ask for the open-ended set by flag, which with anything post-dated is a
  -- picture that has not started -- so "is this slot free" was answered about
  -- the wrong month. Same correction 846 made to the readers.
  IF EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id           = p_employee_id
      AND  p_effective_from BETWEEN s.effective_from AND s.effective_to
      AND  i.relationship_code     = ANY(v_pm_slots)
      AND  i.manager_employee_id   = v_manager_id
      AND  i.removed_on            IS NULL
  ) THEN
    -- Already this employee's manager, through some other project or by hand.
    -- One slot cannot record two owners, so the first owner keeps it.
    RETURN;
  END IF;

  SELECT slot INTO v_slot
  FROM   unnest(v_pm_slots) AS slot
  WHERE  NOT EXISTS (
    SELECT 1
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id       = p_employee_id
      AND  p_effective_from BETWEEN s.effective_from AND s.effective_to
      AND  i.relationship_code = slot
      AND  i.removed_on        IS NULL
  )
  -- MIG 851: LIMIT 1 with no ORDER BY has always been here, and "the first
  -- free slot" was only ever the array order by habit -- nothing obliged the
  -- planner to return PM01 before PM04, and under a different plan it does
  -- not. Which slot a manager lands in is visible to the user and decides
  -- whether they reach the PM01-PM03 mirror at all (G3), so it is not
  -- something to leave to chance.
  ORDER  BY array_position(v_pm_slots, slot)
  LIMIT  1;

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

  -- MIG 851: and record that THIS project is why the slot is filled.
  PERFORM fn_jr_stamp_slot_source(p_employee_id, v_slot, v_manager_id,
                                  p_effective_from, p_project_id);
EXCEPTION WHEN OTHERS THEN
  -- MIG 851: was `NULL`. A sync that cannot run must not also be silent --
  -- 845 sat broken for three months behind exactly this. The membership still
  -- stands; the log says the slot did not follow.
  RAISE WARNING 'MIG 851: sync_project_jr_on_add(%, %) failed: % (%)',
    p_employee_id, p_project_id, SQLERRM, SQLSTATE;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. The remove path asks the slot, not today's manager_id
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sync_project_jr_on_remove(
  p_employee_id uuid, p_project_id uuid, p_removal_date date DEFAULT CURRENT_DATE
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_manager_id uuid;
  v_pm_slots   text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_slot       text;
BEGIN
  -- MIG 851: ask the slot which project owns it. The old code looked up
  -- projects.manager_id and matched on the person, which is the CURRENT lead --
  -- so after a handover, ending a membership released the new lead's slot, or
  -- matched nothing and released none. Provenance is the durable answer.
  SELECT i.relationship_code, i.manager_employee_id
    INTO v_slot, v_manager_id
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  WHERE  s.employee_id        = p_employee_id
    AND  p_removal_date BETWEEN s.effective_from AND s.effective_to
    AND  i.source_project_id  = p_project_id
    AND  i.relationship_code  = ANY(v_pm_slots)
    AND  i.removed_on         IS NULL
  LIMIT 1;

  IF v_slot IS NULL THEN
    -- No owned slot: a row from before 850, or one set by hand. Fall back to
    -- the old behaviour so nothing that worked yesterday stops working.
    SELECT manager_id INTO v_manager_id FROM projects WHERE id = p_project_id;
    IF v_manager_id IS NULL THEN RETURN; END IF;

    SELECT i.relationship_code INTO v_slot
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id         = p_employee_id
      AND  p_removal_date BETWEEN s.effective_from AND s.effective_to
      AND  i.relationship_code   = ANY(v_pm_slots)
      AND  i.manager_employee_id = v_manager_id
      AND  i.removed_on          IS NULL
    LIMIT 1;

    IF v_slot IS NULL THEN RETURN; END IF;
  END IF;

  -- Shared-manager guard (834): another project of this employee's, still
  -- running on the day, led by the same person. The slot is still earned.
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

  PERFORM fn_close_and_replace_job_relationship_set(
    p_employee_id,
    p_removal_date,
    ARRAY[v_slot],
    '[]'::jsonb,
    NULL
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'MIG 851: sync_project_jr_on_remove(%, %) failed: % (%)',
    p_employee_id, p_project_id, SQLERRM, SQLSTATE;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. A lead change moves the slots that project owns
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_project_manager_changed(
  p_project_id uuid,
  p_old        uuid,
  p_new        uuid,
  p_effective  date DEFAULT CURRENT_DATE
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r          record;
  v_slot     text;
  v_other    uuid;
  v_pm_slots text[] := ARRAY['PM01','PM02','PM03','PM04','PM05','PM06'];
  v_moved    int := 0;
  v_ended    int := 0;
  v_kept     int := 0;
  v_skipped  int := 0;
BEGIN
  IF p_old IS NOT DISTINCT FROM p_new THEN
    RETURN jsonb_build_object('ok', true, 'noop', true);
  END IF;

  FOR r IN
    SELECT DISTINCT pm.employee_id
    FROM   project_members pm
    WHERE  pm.project_id     = p_project_id
      AND  pm.employee_id    IS NOT NULL
      AND  pm.effective_from <= p_effective
      AND  (pm.effective_to IS NULL OR pm.effective_to >= p_effective)
  LOOP
    -- The slot THIS project owns, in the picture in force on the day.
    SELECT i.relationship_code INTO v_slot
    FROM   employee_job_relationship_set  s
    JOIN   employee_job_relationship_item i ON i.set_id = s.id
    WHERE  s.employee_id       = r.employee_id
      AND  p_effective BETWEEN s.effective_from AND s.effective_to
      AND  i.source_project_id = p_project_id
      AND  i.relationship_code = ANY(v_pm_slots)
      AND  i.removed_on        IS NULL
    LIMIT 1;

    IF v_slot IS NULL THEN
      -- Nothing here belongs to this project: a slot set by hand, or one
      -- created before 850 and therefore never claimed. Left alone, on
      -- purpose -- this is the promise the column makes.
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- ── The outgoing lead still runs another of this employee's projects ────
    -- 834's rule, applied to a change instead of an ending. The assignment is
    -- still earned, so it stays; ownership passes to the project that still
    -- justifies it, and the incoming lead is placed by the ordinary add path.
    v_other := NULL;
    IF p_old IS NOT NULL THEN
      SELECT pm2.project_id INTO v_other
      FROM   project_members pm2
      JOIN   projects        p2 ON p2.id = pm2.project_id
      WHERE  pm2.employee_id    = r.employee_id
        AND  pm2.project_id     <> p_project_id
        AND  p2.manager_id      = p_old
        AND  pm2.effective_from <= p_effective
        AND  (pm2.effective_to IS NULL OR pm2.effective_to >= p_effective)
      LIMIT 1;
    END IF;

    IF v_other IS NOT NULL THEN
      UPDATE employee_job_relationship_item i
      SET    source_project_id = v_other
      FROM   employee_job_relationship_set s
      WHERE  s.id               = i.set_id
        AND  s.employee_id      = r.employee_id
        AND  s.effective_to    >= p_effective
        AND  i.relationship_code = v_slot
        AND  i.source_project_id = p_project_id;

      PERFORM sync_project_jr_on_add(r.employee_id, p_project_id, p_effective);
      v_kept := v_kept + 1;
      CONTINUE;
    END IF;

    -- ── The lead was cleared ────────────────────────────────────────────────
    -- Nobody is taking over, so the assignment ends -- and 849 gives it a
    -- record day and a strike rather than letting it vanish.
    IF p_new IS NULL THEN
      PERFORM fn_close_and_replace_job_relationship_set(
        r.employee_id, p_effective, ARRAY[v_slot], '[]'::jsonb, NULL);
      v_ended := v_ended + 1;
      CONTINUE;
    END IF;

    -- ── The incoming lead is already this employee's manager ────────────────
    -- Through another project or by hand. Listing them twice would say they
    -- manage the person in two capacities, which is not what happened, so the
    -- slot this project owned simply ends.
    IF EXISTS (
      SELECT 1
      FROM   employee_job_relationship_set  s
      JOIN   employee_job_relationship_item i ON i.set_id = s.id
      WHERE  s.employee_id         = r.employee_id
        AND  p_effective BETWEEN s.effective_from AND s.effective_to
        AND  i.relationship_code   = ANY(v_pm_slots)
        AND  i.manager_employee_id = p_new
        AND  i.removed_on          IS NULL
    ) THEN
      PERFORM fn_close_and_replace_job_relationship_set(
        r.employee_id, p_effective, ARRAY[v_slot], '[]'::jsonb, NULL);
      v_ended := v_ended + 1;
      CONTINUE;
    END IF;

    -- ── The handover ────────────────────────────────────────────────────────
    -- Same slot, new person, from today. A replacement rather than a removal
    -- plus an add: the slot never ended, its occupant changed, and that is
    -- exactly what a set boundary is for. History reads
    --   .. - 30 Sep  PM04 Suchitra
    --   01 Oct - ..  PM04 <the new lead>
    -- with no strike, because nothing was struck.
    PERFORM fn_close_and_replace_job_relationship_set(
      r.employee_id,
      p_effective,
      ARRAY[]::text[],
      jsonb_build_array(jsonb_build_object(
        'relationship_code',   v_slot,
        'manager_employee_id', p_new::text)),
      NULL);

    PERFORM fn_jr_stamp_slot_source(r.employee_id, v_slot, p_new, p_effective, p_project_id);
    v_moved := v_moved + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'moved', v_moved, 'ended', v_ended,
                            'kept', v_kept, 'skipped', v_skipped);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_projects_jr_on_lead_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.manager_id IS NOT DISTINCT FROM NEW.manager_id THEN
    RETURN NEW;
  END IF;

  -- 797's lesson, same table: this runs inside the caller's transaction, so an
  -- unhandled error would roll back the project edit. The save stands and the
  -- failure is logged -- loudly, not swallowed.
  BEGIN
    PERFORM fn_project_manager_changed(NEW.id, OLD.manager_id, NEW.manager_id, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'MIG 851: job-relationship sync for project % failed: % (%). The lead change stands.',
      NEW.id, SQLERRM, SQLSTATE;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS after_project_lead_jr_sync ON public.projects;
CREATE TRIGGER after_project_lead_jr_sync
AFTER UPDATE OF manager_id ON public.projects
FOR EACH ROW EXECUTE FUNCTION public.trg_projects_jr_on_lead_change();

COMMENT ON TRIGGER after_project_lead_jr_sync ON public.projects IS
  'MIG 851: moves the job-relationship slots this project owns when its lead '
  'changes. Separate from 797''s notification trigger on purpose -- one tells '
  'people, this one moves data, and a failure in either must not take the '
  'other down with it.';

-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════
DO $v$
DECLARE
  v_src   text;
  v_probe bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'employee_job_relationship_item'
      AND column_name  = 'source_project_id'
  ) THEN
    RAISE EXCEPTION 'MIG 851 FAILED: source_project_id was not added.';
  END IF;

  -- Nothing was backfilled. Assert it, because a later migration quietly
  -- filling this column would change which slots automation may move.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_item
  WHERE  source_project_id IS NOT NULL
    AND  created_at < now() - interval '1 minute';
  IF v_probe > 0 THEN
    RAISE WARNING 'MIG 851: % pre-existing rows already carry source_project_id. '
                  'Expected 0 on first run; fine on a re-run.', v_probe;
  END IF;

  IF to_regprocedure('public.fn_jr_stamp_slot_source(uuid,text,uuid,date,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIG 851 FAILED: fn_jr_stamp_slot_source() was not created.';
  END IF;
  IF to_regprocedure('public.fn_project_manager_changed(uuid,uuid,uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'MIG 851 FAILED: fn_project_manager_changed() was not created.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE  tgname = 'after_project_lead_jr_sync' AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'MIG 851 FAILED: the lead-change trigger was not created.';
  END IF;

  -- Narrowed to manager_id, 797's rule: a trigger firing on every column edit
  -- would rewrite job relationships when somebody renames a project.
  SELECT pg_get_triggerdef(oid) INTO v_src FROM pg_trigger
  WHERE  tgname = 'after_project_lead_jr_sync' AND NOT tgisinternal;
  IF position('UPDATE OF manager_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 851 FAILED: the trigger is not narrowed to manager_id -- %', v_src;
  END IF;

  -- 797's own trigger must still be there. Two triggers, two jobs.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'after_project_lead_notify' AND NOT tgisinternal
  ) THEN
    RAISE WARNING 'MIG 851: 797''s notification trigger is absent from this database.';
  END IF;

  -- The flag test must be gone from BOTH sync functions, and the date test in.
  FOREACH v_src IN ARRAY ARRAY['sync_project_jr_on_add', 'sync_project_jr_on_remove']
  LOOP
    DECLARE v_body text;
    BEGIN
      SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE  n.nspname = 'public' AND p.proname = v_src;

      IF v_body IS NULL THEN
        RAISE EXCEPTION 'MIG 851 FAILED: %() is missing.', v_src;
      END IF;
      -- Matched as code, not as the bare phrase, so the prose above cannot
      -- fire it. Four deploys have been lost to that; not a fifth.
      IF v_body ~ 'AND[[:space:]]+s\.is_active[[:space:]]*=[[:space:]]*true' THEN
        RAISE EXCEPTION 'MIG 851 FAILED: %() still selects the picture by the is_active flag.', v_src;
      END IF;
      IF position('BETWEEN s.effective_from AND s.effective_to' IN v_body) = 0 THEN
        RAISE EXCEPTION 'MIG 851 FAILED: %() does not select by date.', v_src;
      END IF;
      IF v_body ~ 'EXCEPTION[[:space:]]+WHEN[[:space:]]+OTHERS[[:space:]]+THEN[[:space:]]*\n?[[:space:]]*NULL' THEN
        RAISE EXCEPTION 'MIG 851 FAILED: %() still swallows its errors.', v_src;
      END IF;
    END;
  END LOOP;

  -- AW8: a plpgsql body is not parsed when the function is replaced. Run the
  -- shape of the new lookups against the real tables so every column resolves.
  SELECT count(*) INTO v_probe
  FROM   employee_job_relationship_set  s
  JOIN   employee_job_relationship_item i ON i.set_id = s.id
  LEFT JOIN projects p ON p.id = i.source_project_id
  WHERE  CURRENT_DATE BETWEEN s.effective_from AND s.effective_to
    AND  i.removed_on IS NULL;

  RAISE NOTICE 'MIG 851 OK: a slot records which project filled it, and a lead change moves only those.';
END $v$;

COMMIT;
