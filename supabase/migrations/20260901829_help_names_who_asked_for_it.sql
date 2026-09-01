-- =============================================================================
-- Migration 829 — help names who asked for it
--
-- WHAT IS MISSING TODAY
-- ═════════════════════
-- A support entry has exactly ONE person in it: whoever wrote it. Alice records
-- "5h, AZAD" and there is no second name anywhere in the row, so nothing about
-- it can be checked by anybody. Vj, on why that matters:
--
--   "Else I can randomly assign to any project and it becomes difficult.
--    With this the Project lead can actually question the employee why he
--    took help from others?"
--
-- The problem is not that a field is optional. It is that the row implicates
-- nobody but its author, so there is no one to ask. `help_requested_by` puts a
-- second person in the record and the claim becomes checkable.
--
-- IT IS A CLAIM, NOT CONSENT
--   Naming Naveen does not mean Naveen asked. Nothing here verifies it, and
--   nothing should pretend to. What would make it self-policing is telling him
--   -- a wrong name gets objected to -- and that is deliberately NOT in this
--   migration: it belongs with the project-lead notification work already
--   parked in the design note (S05). The accountability this buys is social:
--   it works because a name is attached, not because a system agreed.
--
-- MANDATORY, AND ENFORCED IN TWO PLACES
--   The RPCs refuse first, with HELP_REQUESTER_REQUIRED and a sentence a person
--   can act on. The trigger refuses second, as rule (i), so a direct table write
--   cannot skip it either. The RPC check exists for the message; the trigger
--   exists for the guarantee. Same arrangement as BILLABLE_REQUIRED (821) and
--   rule (h) (801).
--
--   An optional field here would be worse than none: the entries most worth
--   attributing are exactly the ones that would arrive blank.
--
-- THE EMPLOYEE, NOT THE PROFILE
--   `employees(id)`, not `profiles`. The person who asked for help may have no
--   login at all, and this column is a fact about a person rather than about an
--   actor in the system -- unlike created_by, which is auth.uid() and records
--   who typed.
--
-- ON EXISTING ROWS
--   Every support entry recorded before this has help_requested_by NULL, and
--   rule (i) only fires on INSERT and UPDATE. Nothing existing is invalidated,
--   but any such entry EDITED after this deploys will be asked for a requester
--   -- which is correct, and is the only way old rows ever acquire one.
--
-- Depends on : 801 (routing, rule (h)), 802 (Copy Day carries the column),
--              828 (the column itself, and the widened key)
-- =============================================================================

BEGIN;

-- ── 1. The two write paths ───────────────────────────────────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_fn text;

  -- 801's routing block, verbatim, in both functions. Extended rather than
  -- replaced: the two questions are asked under one condition and reading
  -- v_type.uses_related_project twice would be two places to get it wrong.
  a_route CONSTANT text :=
'  v_rel_id := NULL;' || E'\n' ||
'  IF COALESCE(v_type.uses_related_project, false) THEN' || E'\n' ||
'    v_rel_id  := v_proj_id;' || E'\n' ||
'    v_proj_id := NULL;' || E'\n' ||
'  END IF;' || E'\n';

  b_route CONSTANT text :=
'  v_rel_id := NULL;' || E'\n' ||
'  v_req_id := NULL;' || E'\n' ||
'  IF COALESCE(v_type.uses_related_project, false) THEN' || E'\n' ||
'    v_rel_id  := v_proj_id;' || E'\n' ||
'    v_proj_id := NULL;' || E'\n' ||
'' || E'\n' ||
'    -- mig 829. Who asked. Read ONLY under this condition, so an entry can' || E'\n' ||
'    -- never carry a requester for help it did not give -- the same shape as' || E'\n' ||
'    -- the related project itself, and rule (i) enforces it independently.' || E'\n' ||
'    v_req_id := NULLIF(btrim(COALESCE(p_entry->>''help_requested_by'', '''')), '''')::uuid;' || E'\n' ||
'    IF v_req_id IS NULL THEN' || E'\n' ||
'      RETURN jsonb_build_object(''ok'', false, ''error'', ''HELP_REQUESTER_REQUIRED'',' || E'\n' ||
'        ''message'', ''Say who asked for this help before saving.'');' || E'\n' ||
'    END IF;' || E'\n' ||
'  END IF;' || E'\n';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['save_timesheet_entry', 'bulk_create_timesheet_entries']
  LOOP
    SELECT count(*) INTO v_hits
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: % has % overloads, expected 1.', v_fn, v_hits;
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 829: mig 801 must run first -- % does not route a related project.', v_fn;
    END IF;
    IF position('help_requested_by' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 829: % already records who asked. Nothing to do.', v_fn;
      CONTINUE;
    END IF;

    v_new := v_src;

    -- (a) the declaration, beside the one 801 added.
    v_new := regexp_replace(v_new, '(\n[ \t]*v_rel_id[ \t]+uuid;)',
                            E'\\1\n  v_req_id     uuid;');
    IF position('v_req_id     uuid;' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 829: could not declare v_req_id in % -- no v_rel_id declaration found.', v_fn;
    END IF;

    -- (b) the routing block asks the second question.
    v_hits := (length(v_new) - length(replace(v_new, a_route, ''))) / length(a_route);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: 801''s routing block matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, a_route, b_route);

    -- (c) the INSERT carries it. Same anchors 801 used, one column wider now.
    v_hits := (length(v_new) - length(replace(v_new, 'project_id, related_project_id,', '')))
              / length('project_id, related_project_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: INSERT column list matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, 'project_id, related_project_id,',
                            'project_id, related_project_id, help_requested_by,');

    v_hits := (length(v_new) - length(replace(v_new, 'v_proj_id, v_rel_id,', '')))
              / length('v_proj_id, v_rel_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: INSERT values list matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, 'v_proj_id, v_rel_id,', 'v_proj_id, v_rel_id, v_req_id,');

    -- (d) the UPDATE arm, where there is one. Without this, EDITING a support
    --     entry keeps whatever requester it had while everything else changes.
    IF position('           related_project_id = v_rel_id,' IN v_new) > 0 THEN
      v_new := replace(v_new, '           related_project_id = v_rel_id,',
                              '           related_project_id = v_rel_id,' || E'\n' ||
                              '           help_requested_by  = v_req_id,');
    END IF;

    -- The rules that must survive.
    IF position('BILLABLE_REQUIRED' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 829: the billable refusal (821) was lost from %.', v_fn;
    END IF;
    IF position('mig 828' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 829: the entry lookup fix (828) was lost from %.', v_fn;
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'MIG 829: % now records who asked for the help.', v_fn;
  END LOOP;
END $mig$;


-- ── 2. Rule (i) — the guarantee, independent of any RPC ──────────────────────
--
-- Rule (h) (801) already decides that a help entry must name a project and must
-- not book to one. This is the same condition asking one more thing, so it goes
-- INSIDE (h) rather than beside it -- one lookup of the time type, one place
-- that decides what a help entry has to carry.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  -- The tail of rule (h), verbatim from 801. Ends at the ELSIF so the
  -- replacement can restructure that branch too: a type that does NOT record
  -- help must refuse a requester as well as a related project, and 801's ELSIF
  -- has room for only one test.
  a_h CONSTANT text :=
'      IF NEW.project_id IS NOT NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''Help given to another project cannot also be booked to a project. These hours belong to neither project''''s budget.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'    ELSIF NEW.related_project_id IS NOT NULL THEN' || E'\n' ||
'      RAISE EXCEPTION ''This time type does not record help given to another project, so it cannot name one.''' || E'\n' ||
'        USING ERRCODE = ''check_violation'';' || E'\n' ||
'    END IF;' || E'\n';

  b_h CONSTANT text :=
'      IF NEW.project_id IS NOT NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''Help given to another project cannot also be booked to a project. These hours belong to neither project''''s budget.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'      -- (i) mig 829. Help that names nobody who asked for it cannot be' || E'\n' ||
'      --     questioned by anybody, which is the whole reason it is recorded' || E'\n' ||
'      --     separately from the work it is not part of.' || E'\n' ||
'      IF NEW.help_requested_by IS NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''This time type records help given to another project, so it must name who asked for it.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'    ELSE' || E'\n' ||
'      IF NEW.related_project_id IS NOT NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''This time type does not record help given to another project, so it cannot name one.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'      -- (i), the other half. A requester on an entry that gave no help is a' || E'\n' ||
'      --      name nobody can act on, sitting on a row that will be read by' || E'\n' ||
'      --      reports that do not expect one.' || E'\n' ||
'      IF NEW.help_requested_by IS NOT NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''This time type does not record help given to another project, so it cannot name who asked for it.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'    END IF;' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 829: enforce_timesheet_entry_rules not found.';
  END IF;
  IF position('uses_related_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829: mig 801 must run first -- rule (h) is the anchor.';
  END IF;

  IF position('help_requested_by' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 829: the entry rule already carries (i). Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_h, ''))) / length(a_h);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: rule (h) matched % times, expected 1. 801''s block has moved.', v_hits;
    END IF;
    v_new := replace(v_src, a_h, b_h);
    EXECUTE v_new;
    RAISE NOTICE 'MIG 829: the entry rule now carries (i) -- help names who asked.';
  END IF;
END $mig$;


-- ── 3. Copy Day carries it, and keys on it ───────────────────────────────────
--
-- Without the first, pasting a support day raises rule (i) and the whole paste
-- fails. Without the second, two helps to ONE project from two requesters merge
-- on paste and a requester is lost -- the same argument 802 made about two
-- projects, one level in.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 829: paste_timesheet_day not found.';
  END IF;
  IF position('related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829: mig 802 must run first.';
  END IF;

  IF position('help_requested_by' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 829: paste_timesheet_day already carries the requester. Nothing to do.';
  ELSE
    v_new := v_src;

    -- (a) it must be SELECTED from the source day.
    v_hits := (length(v_new) - length(replace(v_new, 'e.project_id, e.related_project_id,', '')))
              / length('e.project_id, e.related_project_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: the source SELECT matched % times in paste, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, 'e.project_id, e.related_project_id,',
                            'e.project_id, e.related_project_id, e.help_requested_by,');

    -- (b) the collision key, one level finer than 802 made it.
    v_hits := (length(v_new) - length(replace(v_new, 'AND  e.related_project_id IS NOT DISTINCT FROM r.related_project_id;', '')))
              / length('AND  e.related_project_id IS NOT DISTINCT FROM r.related_project_id;');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: 802''s collision key matched % times in paste, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new,
      'AND  e.related_project_id IS NOT DISTINCT FROM r.related_project_id;',
      'AND  e.related_project_id IS NOT DISTINCT FROM r.related_project_id' || E'\n' ||
      '      -- mig 829. Two people on one project asking for help on one day' || E'\n' ||
      '      -- are two facts. Without this the paste merges them and one of' || E'\n' ||
      '      -- the two requesters is simply lost.' || E'\n' ||
      '      AND  e.help_requested_by IS NOT DISTINCT FROM r.help_requested_by;');

    -- (c) the INSERT carries it, or rule (i) refuses the whole paste.
    v_hits := (length(v_new) - length(replace(v_new, 'time_type_id, project_id, related_project_id,', '')))
              / length('time_type_id, project_id, related_project_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: the paste INSERT column list matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, 'time_type_id, project_id, related_project_id,',
                            'time_type_id, project_id, related_project_id, help_requested_by,');

    v_hits := (length(v_new) - length(replace(v_new, 'r.time_type_id, r.project_id, r.related_project_id,', '')))
              / length('r.time_type_id, r.project_id, r.related_project_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 829: the paste INSERT values list matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, 'r.time_type_id, r.project_id, r.related_project_id,',
                            'r.time_type_id, r.project_id, r.related_project_id, r.help_requested_by,');

    EXECUTE v_new;
    RAISE NOTICE 'MIG 829: paste_timesheet_day now carries and keys on the requester.';
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  v_name text;
  v_pos_rel integer;
  v_pos_req integer;
BEGIN
  -- ── Both write paths ──────────────────────────────────────────────────────
  FOR v_name, v_src IN
    SELECT p.proname, pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    IF position('HELP_REQUESTER_REQUIRED' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 829 FAILED: % does not refuse help with no requester, so the trigger would raise a raw constraint error instead of a sentence.', v_name;
    END IF;
    IF position('help_requested_by,' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 829 FAILED: %''s INSERT does not carry the column, so every save would be refused by rule (i).', v_name;
    END IF;
    IF position('v_rel_id, v_req_id,' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 829 FAILED: %''s INSERT does not pass the value.', v_name;
    END IF;

    -- Read UNDER the flag, not before it. Reading the key unconditionally would
    -- store a requester on an ordinary work entry the moment a stale form sent
    -- one, and rule (i) would then refuse a save the employee cannot fix.
    v_pos_rel := position('v_rel_id  := v_proj_id;' IN v_src);
    v_pos_req := position('v_req_id := NULLIF' IN v_src);
    IF v_pos_rel = 0 OR v_pos_req = 0 THEN
      RAISE EXCEPTION 'MIG 829 FAILED: the routing block in % is not shaped as expected.', v_name;
    END IF;
    IF v_pos_req < v_pos_rel THEN
      RAISE EXCEPTION 'MIG 829 FAILED: % reads the requester outside the branch that decides whether help was given at all.', v_name;
    END IF;
  END LOOP;

  -- ── Rule (i), both halves ─────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules';

  IF position('it must name who asked for it' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829 FAILED: rule (i) does not require a requester on help.';
  END IF;
  IF position('it cannot name who asked for it' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829 FAILED: rule (i) does not refuse a requester on an entry that gave no help. Half a rule is a rule that will be worked around.';
  END IF;
  -- Rule (h) must have survived being rewritten around.
  IF position('so it must name that project' IN v_src) = 0
     OR position('cannot also be booked to a project' IN v_src) = 0
     OR position('so it cannot name one' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829 FAILED: rule (h) (801) lost one of its three refusals.';
  END IF;

  -- ── Copy Day ──────────────────────────────────────────────────────────────
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('r.help_requested_by,' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829 FAILED: paste does not carry the requester, so every support day would fail rule (i) on paste.';
  END IF;
  IF position('e.help_requested_by IS NOT DISTINCT FROM r.help_requested_by' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 829 FAILED: paste''s collision key ignores the requester, so two requesters on one project merge and one is lost.';
  END IF;

  RAISE NOTICE 'Migration 829 verified: both write paths record and require a requester, rule (i) enforces it in both directions, and Copy Day carries and keys on it.';
END $mig$;

COMMIT;
