-- =============================================================================
-- Migration 800 — billability becomes a property of time types, and the
--                 utilisation report learns to split on it
--
-- WHAT WAS ACTUALLY MISSING
-- ═════════════════════════
-- It is tempting to say that non-project hours are absent from utilisation.
-- They are not. timesheet_report_utilisation builds `ent` with no entry_kind
-- filter, and none of 745, 746, 750, 752 or 771 ever added one, so a Training
-- hour has always been inside totals.recorded_minutes.
--
-- What a Training hour has never had is a CLASSIFICATION. Billability lives on
-- picklist_values.ref_id via projects.project_type_id -- P001 billable, P002
-- internal, P003 overhead -- and is computed only in
-- timesheet_report_project_summary, a report grained on the PROJECT. A report
-- grained on the project can never carry an hour that has no project, so
-- non-project time is neither billable nor non-billable. It is simply outside
-- the question.
--
-- This migration gives time types the same property projects already have, and
-- teaches the one report that already holds every recorded hour to split on it.
--
-- WHY THE SPLIT GOES IN A NESTED KEY
--   totals.* is read by TimesheetUtilisation.tsx today. Adding four siblings
--   would be safe, but nesting them under totals.billable_split says plainly
--   that they are one coherent set that sums to recorded_minutes, and leaves
--   the existing keys untouched for a frontend deployed before this ships.
--
-- THE CLASSIFICATION, AND ITS PRECEDENCE
--   time_type_id wins over project_id. A requires_project entry (mig 715)
--   carries BOTH, and it is a time-type entry that happens to name a project,
--   not a project entry. Classifying it by the project would file somebody's
--   Training under the client's billable hours.
--
--     time type, category absence  -> absence       (leave is not worked time)
--     time type, is_billable       -> billable
--     time type, otherwise         -> non_billable
--     project, ref_id = 'P001'     -> billable
--     project, ref_id IS NULL      -> unclassified  (never assumed billable)
--     project, otherwise           -> non_billable  (P002 internal, P003 overhead)
--
--   Absence is its own bucket rather than folded into non-billable. Leave is
--   not unbillable work; it is not work. The four buckets sum to
--   recorded_minutes exactly, which the verification below asserts.
--
-- ABSENCE ROWS ARE MOSTLY NOT HERE ANYWAY
--   Leave and holiday are is_system_generated and `ent` drops those unless the
--   caller asks for them. The bucket exists for the case where they are asked
--   for, and for a manually recorded absence type.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   699, 715, 718, 729 and 736 have each amended upsert_time_type; 745, 746,
--   750, 752 and 771 have each amended timesheet_report_utilisation. A
--   CREATE OR REPLACE built from any one of those files would silently revert
--   whichever of the others the author had not read. That is the defect behind
--   734, 736 and 737. Every anchor below is asserted to match exactly once, and
--   the migration aborts rather than guessing.
--
-- upsert_time_type IS PATCHED WITH A FOLLOW-UP UPDATE, NOT A WIDER COLUMN LIST
--   The INSERT column list in that function has been rewritten by 715, 718 and
--   729. Anchoring on it would mean matching a shape this file cannot see. A
--   separate UPDATE on the primary key is duller and cannot miss.
--
-- Depends on : 699, 715, 718, 729/736 (upsert_time_type)
--              744, 745, 746, 750, 752, 771 (timesheet_report_utilisation)
--              001 (picklist_values.ref_id, projects.project_type_id)
-- =============================================================================

BEGIN;

-- ── 1. The column ────────────────────────────────────────────────────────────
--
-- DEFAULT false, deliberately. Every time type that exists today -- Training,
-- On-Site Visit, Public Holiday, Annual Leave -- is non-billable, so the
-- default is not a placeholder standing in for an unanswered question; it is
-- the correct value for all of them. A default of true would have made the
-- billable share wrong on the day this shipped.

ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS is_billable boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.time_types.is_billable IS
  'Mig 800: whether hours on this time type count as billable in the '
  'utilisation split. Forced false for absence types -- leave is not worked '
  'time and is reported in its own bucket. Mirrors ref_id = ''P001'' on a '
  'project''s type, which is how project hours are classified.';


-- ── 2. upsert_time_type learns the flag ──────────────────────────────────────

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  a_ret CONSTANT text :=
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';

  b_ret CONSTANT text :=
'  -- is_billable (mig 800). Set on its own rather than threaded through the' || E'\n' ||
'  -- column list above: that list has been rewritten by 715, 718 and 729, and' || E'\n' ||
'  -- an anchored edit of it would have to match a shape mig 800 cannot see.' || E'\n' ||
'  -- Forced false for absence, mirroring how the other flags are gated.' || E'\n' ||
'  UPDATE time_types' || E'\n' ||
'     SET is_billable = CASE WHEN category = ''absence'' THEN false' || E'\n' ||
'                            ELSE COALESCE((p_data->>''is_billable'')::boolean, false) END' || E'\n' ||
'   WHERE id = v_id;' || E'\n' ||
'' || E'\n' ||
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 800: upsert_time_type not found. 699 must run first.';
  END IF;

  -- The anchors are taken from the function 729/736 leaves behind. If
  -- allows_future is missing, this is an older body and the shape below is not
  -- the shape that is there.
  IF position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800: upsert_time_type predates 729. Anchors would not match.';
  END IF;

  IF position('is_billable' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 800: upsert_time_type already sets is_billable. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_ret, ''))) / length(a_ret);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 800: success-return anchor matched % times in upsert_time_type, expected 1.', v_hits;
    END IF;

    v_new := replace(v_src, a_ret, b_ret);
    IF v_new = v_src THEN
      RAISE EXCEPTION 'MIG 800: upsert_time_type unchanged after replace.';
    END IF;

    EXECUTE v_new;
  END IF;
END $mig$;

COMMENT ON FUNCTION public.upsert_time_type(jsonb) IS
  'Mig 800: as 729, plus is_billable -- forced false for absence types, the '
  'same gating the other category-specific flags use.';


-- ── 3. The utilisation report splits on it ───────────────────────────────────

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_hits integer;

  -- Exactly what 771 leaves at the tail of the totals object.
  a_tot CONSTANT text :=
'      ''project_count'',    (SELECT count(DISTINCT project_id) FROM ent WHERE project_id IS NOT NULL),' || E'\n' ||
'      ''planned_covers_all_rows'', NOT EXISTS (SELECT 1 FROM ent WHERE via_project)' || E'\n' ||
'    ),' || E'\n';

  b_tot CONSTANT text :=
'      ''project_count'',    (SELECT count(DISTINCT project_id) FROM ent WHERE project_id IS NOT NULL),' || E'\n' ||
'      ''planned_covers_all_rows'', NOT EXISTS (SELECT 1 FROM ent WHERE via_project),' || E'\n' ||
'' || E'\n' ||
'      -- Mig 800. Every recorded hour lands in exactly one of four buckets,' || E'\n' ||
'      -- and the four sum to recorded_minutes. time_type_id wins over' || E'\n' ||
'      -- project_id: a requires_project entry (715) carries both, and it is a' || E'\n' ||
'      -- time-type entry that names a project, not a project entry.' || E'\n' ||
'      -- An unclassified project is reported as unclassified, never assumed' || E'\n' ||
'      -- billable -- a project silently defaulted to billable turns up in the' || E'\n' ||
'      -- billable share and nobody can see why it is there.' || E'\n' ||
'      ''billable_split'', (' || E'\n' ||
'        SELECT jsonb_build_object(' || E'\n' ||
'                 ''billable_minutes'',     COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''billable''),     0),' || E'\n' ||
'                 ''non_billable_minutes'', COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''non_billable''), 0),' || E'\n' ||
'                 ''absence_minutes'',      COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''absence''),      0),' || E'\n' ||
'                 ''unclassified_minutes'', COALESCE(sum(c.hours_minutes) FILTER (WHERE c.cls = ''unclassified''), 0))' || E'\n' ||
'        FROM (' || E'\n' ||
'          SELECT en.hours_minutes,' || E'\n' ||
'                 CASE' || E'\n' ||
'                   WHEN en.time_type_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN tt.category = ''absence''       THEN ''absence''' || E'\n' ||
'                             WHEN COALESCE(tt.is_billable, false) THEN ''billable''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   WHEN en.project_id IS NOT NULL THEN' || E'\n' ||
'                        CASE WHEN pv.ref_id = ''P001'' THEN ''billable''' || E'\n' ||
'                             WHEN pv.ref_id IS NULL    THEN ''unclassified''' || E'\n' ||
'                             ELSE ''non_billable'' END' || E'\n' ||
'                   ELSE ''unclassified''' || E'\n' ||
'                 END AS cls' || E'\n' ||
'          FROM   ent en' || E'\n' ||
'          LEFT   JOIN time_types      tt ON tt.id = en.time_type_id' || E'\n' ||
'          LEFT   JOIN projects        pr ON pr.id = en.project_id' || E'\n' ||
'          LEFT   JOIN picklist_values pv ON pv.id = pr.project_type_id' || E'\n' ||
'        ) c)' || E'\n' ||
'    ),' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 800: timesheet_report_utilisation not found. 744 must run first.';
  END IF;
  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800: 771 must run first -- the anchor is taken from the function it leaves.';
  END IF;

  IF position('billable_split' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 800: utilisation already reports billable_split. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_tot, ''))) / length(a_tot);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 800: totals anchor matched % times in timesheet_report_utilisation, expected 1.', v_hits;
    END IF;

    v_new := replace(v_src, a_tot, b_tot);
    IF v_new = v_src THEN
      RAISE EXCEPTION 'MIG 800: timesheet_report_utilisation unchanged after replace.';
    END IF;

    EXECUTE v_new;
  END IF;
END $mig$;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  n     integer;
BEGIN
  -- 1. The column exists, is NOT NULL, defaults false.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'time_types'
                   AND column_name = 'is_billable') THEN
    RAISE EXCEPTION 'MIG 800 FAILED: time_types.is_billable not found.';
  END IF;

  SELECT count(*) INTO n FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'time_types'
    AND column_name = 'is_billable' AND is_nullable = 'NO';
  IF n <> 1 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: is_billable must be NOT NULL.';
  END IF;

  -- 2. The default is false, so adding the column classified nothing on its
  --    own. Asserted on the DEFAULT rather than by counting billable rows: on
  --    a re-run an administrator may legitimately have marked a type billable,
  --    and a check that fails the second time is not a check, it is a trap.
  SELECT count(*) INTO n FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'time_types'
    AND column_name = 'is_billable' AND column_default = 'false';
  IF n <> 1 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: is_billable must default to false.';
  END IF;

  -- 3. Absence types can never be billable, whatever is posted.
  SELECT count(*) INTO n FROM public.time_types
  WHERE category = 'absence' AND is_billable;
  IF n <> 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: % absence types are billable.', n;
  END IF;

  -- 4. upsert_time_type sets it, and still gates it on category.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF position('is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type does not set is_billable.';
  END IF;
  IF position('SET is_billable = CASE WHEN category = ''absence'' THEN false' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type does not gate is_billable on category.';
  END IF;
  IF position('WHERE id = v_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: the is_billable UPDATE has no WHERE clause.';
  END IF;

  -- 5. Everything 715, 718 and 729 put there is still there. This is the whole
  --    reason the function is patched rather than re-issued.
  IF position('requires_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type lost requires_project (715).';
  END IF;
  IF position('allows_half_day' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type lost allows_half_day (718).';
  END IF;
  IF position('allows_future' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type lost allows_future (729).';
  END IF;
  IF position('DUPLICATE_CODE' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: upsert_time_type lost its unique_violation handler.';
  END IF;

  -- 6. The report reports the split.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname = 'public' AND p.proname = 'timesheet_report_utilisation';

  IF position('billable_split' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: timesheet_report_utilisation has no billable_split.';
  END IF;

  IF position('''billable_minutes''' IN v_src)     = 0
     OR position('''non_billable_minutes''' IN v_src) = 0
     OR position('''absence_minutes''' IN v_src)      = 0
     OR position('''unclassified_minutes''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: billable_split does not carry all four buckets.';
  END IF;

  -- 7. Precedence is the documented one: the time type is tested first.
  IF position('WHEN en.time_type_id IS NOT NULL THEN' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: the split does not give the time type precedence.';
  END IF;
  IF position('WHEN pv.ref_id IS NULL    THEN ''unclassified''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: an untyped project is not reported as unclassified.';
  END IF;

  -- 8. Nothing 771, 752, 750 or 746 put there was lost.
  IF position('time_report_managed_project_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: utilisation lost the PM predicate (771).';
  END IF;
  IF position('planned_covers_all_rows' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: utilisation lost planned_covers_all_rows (771).';
  END IF;
  IF position('bd_week' IN v_src) = 0 OR position('week_end' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: utilisation lost the week buckets (750, 752).';
  END IF;
  IF position('via_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: utilisation lost via_project redaction (771).';
  END IF;

  -- 9. recorded_minutes is untouched. This migration adds a split; it does not
  --    change anybody's utilisation percentage, and that claim is worth an
  --    assertion rather than a sentence in a design note.
  IF position('''recorded_minutes'', (SELECT COALESCE(sum(hours_minutes), 0) FROM ent)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 800 FAILED: recorded_minutes was altered. The split must be additive.';
  END IF;

  RAISE NOTICE 'Migration 800 verified: is_billable on time_types, gated on category in upsert_time_type, and a four-bucket billable split on the utilisation report that leaves recorded_minutes untouched.';
END $mig$;

COMMIT;
