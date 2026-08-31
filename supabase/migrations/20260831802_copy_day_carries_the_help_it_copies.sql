-- =============================================================================
-- Migration 802 — Copy Day carries the help it copies, and the flag stops
--                 being flippable once it means something
--
-- TWO HOLES LEFT OPEN BY 801, CLOSED TOGETHER BECAUSE THEY ARE THE SAME HOLE
-- ═════════════════════════════════════════════════════════════════════════
-- 801 routes a support entry's project to related_project_id. Two paths did not
-- learn about the column, and in both cases the failure is the same shape: the
-- entry survives, the fact of WHO WAS HELPED does not.
--
--   1. paste_timesheet_day copies (entry_kind, time_type_id, project_id, ...).
--      A pasted support entry would arrive with related_project_id NULL, and
--      rule (h) would refuse it. Safe -- nothing is written -- but the employee
--      sees Copy Day fail on a day that looked ordinary, with a message about a
--      rule they have never heard of.
--
--   2. upsert_time_type lets an administrator flip uses_related_project on a
--      type that already has months of hours behind it. Nothing breaks loudly.
--      The old hours stay in project_id, the new ones go to
--      related_project_id, and the same type now means two different things
--      depending on when the entry was made. No report can tell them apart,
--      and no error is ever raised. That is the worse of the two.
--
-- THE COLLISION KEY IS THE SUBTLE PART
-- ────────────────────────────────────
-- Paste decides "does the target day already hold this entry?" on
-- (time_type_id, project_id). For support entries project_id is NULL on every
-- one of them, so two entries helping DIFFERENT projects on the same day read
-- as the same entry, and the second would be merged into the first -- summing
-- hours given to Acme with hours given to Beta under whichever name arrived
-- first. The key has to include related_project_id, or the migration that
-- teaches paste to carry the column also teaches it to corrupt the copy.
--
-- THE LABEL, WHILE WE ARE HERE
-- ----------------------------
-- Paste's messages name the entry as "<type> — <project>", read from
-- project_id. On a support entry that is NULL, so every message would say only
-- "Support to Another Project" and a user with two of them could not tell which
-- one the message meant. COALESCE onto related_project_id fixes it.
--
-- WHY THE FLAG GUARD IS A REFUSAL AND NOT A MIGRATION OF THE OLD ROWS
--   Moving historical hours from project_id to related_project_id would change
--   what every past report said about a project that has already been invoiced
--   and reported on. Refusing the flip and asking for a new type leaves history
--   alone, which is the only answer that does not rewrite the past.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   735, 737, 738, 741, 772, 775 and 776 have each amended
--   paste_timesheet_day. 699, 715, 718, 729, 736, 800 and 801 have each amended
--   upsert_time_type. Every anchor is asserted to match exactly once.
--
-- Depends on : 776 (paste), 800, 801
-- =============================================================================

BEGIN;

-- ── 1. Paste carries the column, keys on it, and names it ────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_sel CONSTANT text :=
'    SELECT e.id, e.entry_kind, e.time_type_id, e.project_id, e.hours_minutes,' || E'\n';
  b_sel CONSTANT text :=
'    SELECT e.id, e.entry_kind, e.time_type_id, e.project_id, e.related_project_id, e.hours_minutes,' || E'\n';

  -- The collision key. Without the second line, two support entries helping
  -- different projects on one day merge into one.
  a_key CONSTANT text :=
'      AND  e.project_id   IS NOT DISTINCT FROM r.project_id;' || E'\n';
  b_key CONSTANT text :=
'      AND  e.project_id   IS NOT DISTINCT FROM r.project_id' || E'\n' ||
'      -- mig 802. Support entries all carry project_id NULL, so without this' || E'\n' ||
'      -- line help given to Acme and help given to Beta on the same day read as' || E'\n' ||
'      -- the same entry and the second is merged into the first.' || E'\n' ||
'      AND  e.related_project_id IS NOT DISTINCT FROM r.related_project_id;' || E'\n';

  a_lbl CONSTANT text :=
'       LEFT   JOIN projects pr ON pr.id = r.project_id' || E'\n';
  b_lbl CONSTANT text :=
'       -- mig 802. A support entry books to no project, so without the' || E'\n' ||
'       -- COALESCE every message about one would name only the time type.' || E'\n' ||
'       LEFT   JOIN projects pr ON pr.id = COALESCE(r.project_id, r.related_project_id)' || E'\n';

  a_ins CONSTANT text :=
'        (header_id, entry_date, entry_kind, time_type_id, project_id,' || E'\n' ||
'         hours_minutes, notes, activities, created_by)' || E'\n' ||
'      VALUES' || E'\n' ||
'        (p_header_id, p_to_date, r.entry_kind, r.time_type_id, r.project_id,' || E'\n';
  b_ins CONSTANT text :=
'        (header_id, entry_date, entry_kind, time_type_id, project_id, related_project_id,' || E'\n' ||
'         hours_minutes, notes, activities, created_by)' || E'\n' ||
'      VALUES' || E'\n' ||
'        (p_header_id, p_to_date, r.entry_kind, r.time_type_id, r.project_id, r.related_project_id,' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 802: paste_timesheet_day not found. 735 must run first.';
  END IF;
  IF position('act_rows' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802: 776 must run first -- the anchors are taken from the function it leaves.';
  END IF;

  IF position('related_project_id' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 802: paste_timesheet_day already carries the related project. Nothing to do.';
  ELSE
    v_new := v_src;

    v_hits := (length(v_new) - length(replace(v_new, a_sel, ''))) / length(a_sel);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 802: the source SELECT matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_sel, b_sel);

    v_hits := (length(v_new) - length(replace(v_new, a_key, ''))) / length(a_key);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 802: the collision key matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_key, b_key);

    v_hits := (length(v_new) - length(replace(v_new, a_lbl, ''))) / length(a_lbl);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 802: the label join matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_lbl, b_lbl);

    v_hits := (length(v_new) - length(replace(v_new, a_ins, ''))) / length(a_ins);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 802: the INSERT matched % times, expected 1.', v_hits;
    END IF;
    v_new := replace(v_new, a_ins, b_ins);

    EXECUTE v_new;
    RAISE NOTICE 'MIG 802: paste_timesheet_day now copies, keys on, and names the related project.';
  END IF;
END $mig$;


-- ── 2. The flag stops being flippable once hours exist ───────────────────────
--
-- Placed BEFORE the upsert rather than beside the 801 UPDATE that sets the
-- flag. By that point the row has already been written, and returning an error
-- envelope from a function that has already changed the row would commit the
-- half of the edit the administrator was told had failed.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_cat CONSTANT text :=
'  IF (p_data->>''category'') NOT IN (''attendance'', ''absence'') THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''INVALID_CATEGORY'',' || E'\n' ||
'      ''message'', ''category must be attendance or absence.'');' || E'\n' ||
'  END IF;' || E'\n';

  b_cat CONSTANT text :=
'  IF (p_data->>''category'') NOT IN (''attendance'', ''absence'') THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''INVALID_CATEGORY'',' || E'\n' ||
'      ''message'', ''category must be attendance or absence.'');' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  -- mig 802. uses_related_project decides which COLUMN an entry''''s project' || E'\n' ||
'  -- lands in. Flipping it on a type with hours behind it would leave the old' || E'\n' ||
'  -- ones in project_id and the new ones in related_project_id -- one type' || E'\n' ||
'  -- meaning two things, with nothing raised and no report able to separate' || E'\n' ||
'  -- them. Refused rather than migrated: moving the old rows would change what' || E'\n' ||
'  -- past reports said about projects that have already been invoiced.' || E'\n' ||
'  IF NOT v_is_new' || E'\n' ||
'     AND COALESCE((p_data->>''uses_related_project'')::boolean, false)' || E'\n' ||
'         IS DISTINCT FROM (SELECT tt.uses_related_project FROM time_types tt WHERE tt.id = v_id)' || E'\n' ||
'     AND EXISTS (SELECT 1 FROM timesheet_entries te WHERE te.time_type_id = v_id) THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''TYPE_IN_USE'',' || E'\n' ||
'      ''message'', ''Hours have already been recorded against this time type, so how it records a project can no longer be changed. Create a new time type instead.'');' || E'\n' ||
'  END IF;' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 802: upsert_time_type not found.';
  END IF;
  IF position('uses_related_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802: mig 801 must run first.';
  END IF;

  IF position('TYPE_IN_USE' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 802: upsert_time_type already guards the flag. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_cat, ''))) / length(a_cat);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 802: the category guard matched % times in upsert_time_type, expected 1.', v_hits;
    END IF;
    v_new := replace(v_src, a_cat, b_cat);
    EXECUTE v_new;
    RAISE NOTICE 'MIG 802: upsert_time_type now refuses to reclassify a type that is in use.';
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'paste_timesheet_day';

  IF position('e.related_project_id, e.hours_minutes' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: paste does not read related_project_id.';
  END IF;
  IF position('e.related_project_id IS NOT DISTINCT FROM r.related_project_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: the collision key ignores the related project. Two helps on one day would merge.';
  END IF;
  IF position('COALESCE(r.project_id, r.related_project_id)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: paste messages would not name the helped project.';
  END IF;
  IF position('r.time_type_id, r.project_id, r.related_project_id,' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: paste does not write related_project_id.';
  END IF;

  -- Everything the seven earlier migrations put here is still here.
  IF position('act_rows' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: paste lost the activity-row count (776).';
  END IF;
  IF position('is_system_generated' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: paste lost its system-generated guard.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF position('TYPE_IN_USE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: the reclassification guard is missing.';
  END IF;
  -- It must sit before the write, or the refusal commits half an edit.
  IF position('TYPE_IN_USE' IN v_src) > position('INSERT INTO time_types' IN v_src) THEN
    RAISE EXCEPTION 'MIG 802 FAILED: the guard is after the INSERT. It must refuse before anything is written.';
  END IF;
  IF position('is_billable' IN v_src) = 0 OR position('uses_related_project' IN v_src) = 0
     OR position('requires_project' IN v_src) = 0 OR position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 802 FAILED: upsert_time_type lost a flag from 715, 718, 729, 800 or 801.';
  END IF;

  RAISE NOTICE 'Migration 802 verified: Copy Day carries, keys on and names the related project, and a time type in use can no longer be reclassified.';
END $mig$;

COMMIT;
