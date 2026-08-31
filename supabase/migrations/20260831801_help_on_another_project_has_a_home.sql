-- =============================================================================
-- Migration 801 — help given to another project has somewhere to go
--
-- THE PROBLEM
-- ═══════════
-- Ravi is on Beta Migration. He spends a Wednesday helping Acme Rollout. His
-- dropdown offers only Beta Migration, so the four hours are either lost or
-- filed against a project he was not working on.
--
-- The dropdown offers a project when you are a member OR have ever booked to
-- it. The second arm is date-blind on purpose, so an old entry can always name
-- its own project. The result is a rule nobody chose: the FIRST hour of help is
-- blocked, and every hour after it is permitted for ever.
--
-- WHY THE HOURS MUST NOT LAND IN project_id
-- ─────────────────────────────────────────
-- Design decision D6: help must be visible on the helped project without
-- entering its utilisation, burn or cost. Four functions read
-- timesheet_entries.project_id with no entry_kind test:
--
--   timesheet_report_project_summary   recorded_minutes, contributors, billable
--   timesheet_report_utilisation       project_count, and the by-project filter
--   my_staffable_projects              reads as a project you have worked
--   my_timesheet_projects              the `booked` arm -- help Acme once and
--                                      Acme joins your ordinary dropdown for ever
--
-- Teaching four functions to exclude a category is separation by convention: it
-- holds until somebody writes a fifth report. A separate column is separation
-- by construction -- those readers cannot see it because they do not select it.
--
-- THE MECHANISM, WHICH IS MOSTLY ALREADY BUILT
-- ════════════════════════════════════════════
-- 715 gave time types requires_project, and relaxed the entry constraint so a
-- non-project entry may carry a project. 721 made such an entry name at least
-- one activity. 727 gave it per-activity hours. 776 gave it merge rules, and
-- 738 the daily cap. All of that is reused untouched.
--
-- One flag is added: uses_related_project. It is meaningful only on a type that
-- already requires a project, and it says one thing -- the project the employee
-- picked is NOT the project these hours belong to. At the write sites the id is
-- routed to related_project_id and project_id is left NULL.
--
-- So the type behaves exactly like existing project time in every respect the
-- employee can see, and behaves like nothing at all to every report.
--
-- THE TYPE IS SEEDED INACTIVE, DELIBERATELY
--   The database and the frontend ship on different workflows. Until the screen
--   carrying the unfiltered picker is live, this type would offer the NARROWED
--   project list -- the very list that cannot contain the project you want to
--   help. An administrator activates it on the Time Types screen when the
--   frontend is out. Seeding it active would mean a window in which the feature
--   is reachable and wrong.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   Copy Day does not carry related_project_id yet. Rule (h) below will refuse
--   such a paste with a message rather than write an entry that breaks the
--   rule, and the type is inactive, so the path is unreachable until 802
--   teaches paste to carry the column.
--
-- PATCHED IN PLACE, NOT RE-ISSUED
--   699, 715, 718, 729, 736 and 800 have each amended upsert_time_type. 721,
--   726, 729, 730, 736, 738 and 739 have each amended
--   enforce_timesheet_entry_rules. save_timesheet_entry and
--   bulk_create_timesheet_entries have their own chains. A CREATE OR REPLACE
--   built from any one of those files would silently revert the others -- the
--   defect behind 734, 736 and 737. Every anchor is asserted to match exactly
--   once and the migration aborts rather than guessing.
--
-- Depends on : 715, 721, 727, 729/736, 738, 800
-- =============================================================================

BEGIN;

-- ── 1. The flag on the time type ─────────────────────────────────────────────

ALTER TABLE public.time_types
  ADD COLUMN IF NOT EXISTS uses_related_project boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.time_types.uses_related_project IS
  'Mig 801: the project chosen on this entry is the project being HELPED, not '
  'the project the hours belong to. Routed to '
  'timesheet_entries.related_project_id, leaving project_id NULL so no project '
  'report can count it. Meaningful only when requires_project is true.';


-- ── 2. The column on the entry ───────────────────────────────────────────────
--
-- Deliberately NOT added to the te_project_kind CHECK. That constraint governs
-- which of project_id / time_type_id an entry_kind may carry; this column is a
-- reference to somebody else's project and is orthogonal to it. The rule that
-- governs it needs to read time_types, which a CHECK cannot do, so it lives in
-- the entry trigger with every other cross-table rule.

ALTER TABLE public.timesheet_entries
  ADD COLUMN IF NOT EXISTS related_project_id uuid REFERENCES public.projects(id);

COMMENT ON COLUMN public.timesheet_entries.related_project_id IS
  'Mig 801: the project this time HELPED, for time types with '
  'uses_related_project. Never project_id: these hours must not reach that '
  'project''s utilisation, burn or cost. Reporting on help reads this column '
  'and nothing else does.';

-- Reporting: who helped which project, over a period.
CREATE INDEX IF NOT EXISTS idx_tse_related_project_date
  ON public.timesheet_entries (related_project_id, entry_date)
  WHERE related_project_id IS NOT NULL;


-- ── 3. upsert_time_type learns the flag ──────────────────────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_ret CONSTANT text :=
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';

  b_ret CONSTANT text :=
'  -- uses_related_project (mig 801). Gated on requires_project rather than on' || E'\n' ||
'  -- category: a type that names no project cannot name another team''''s.' || E'\n' ||
'  UPDATE time_types' || E'\n' ||
'     SET uses_related_project = CASE WHEN requires_project' || E'\n' ||
'                                     THEN COALESCE((p_data->>''uses_related_project'')::boolean, false)' || E'\n' ||
'                                     ELSE false END' || E'\n' ||
'   WHERE id = v_id;' || E'\n' ||
'' || E'\n' ||
'  RETURN jsonb_build_object(''ok'', true, ''id'', v_id, ''created'', v_is_new);' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'upsert_time_type';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 801: upsert_time_type not found.';
  END IF;
  IF position('is_billable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 801: mig 800 must run first -- the anchor is taken from the function it leaves.';
  END IF;

  IF position('uses_related_project' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 801: upsert_time_type already sets uses_related_project. Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_ret, ''))) / length(a_ret);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 801: success-return anchor matched % times in upsert_time_type, expected 1.', v_hits;
    END IF;
    v_new := replace(v_src, a_ret, b_ret);
    IF v_new = v_src THEN
      RAISE EXCEPTION 'MIG 801: upsert_time_type unchanged after replace.';
    END IF;
    EXECUTE v_new;
  END IF;
END $mig$;


-- ── 4. The entry rule ────────────────────────────────────────────────────────
--
-- Rule (h): the column and the flag agree, and a related project never doubles
-- as the booked project. Stated as two failures with two messages, because
-- "related_project_id is invalid" tells a user nothing about what to do.

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer;

  a_end CONSTANT text :=
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  RETURN NEW;' || E'\n' ||
'END;' || E'\n';

  b_end CONSTANT text :=
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  -- (h) mig 801. The helped project and the booked project are different' || E'\n' ||
'  --     questions, and an entry may answer only the one its time type asks.' || E'\n' ||
'  IF NEW.time_type_id IS NOT NULL THEN' || E'\n' ||
'    SELECT COALESCE(tt.uses_related_project, false) INTO v_uses_rel' || E'\n' ||
'    FROM   time_types tt WHERE tt.id = NEW.time_type_id;' || E'\n' ||
'' || E'\n' ||
'    IF COALESCE(v_uses_rel, false) THEN' || E'\n' ||
'      IF NEW.related_project_id IS NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''This time type records help given to another project, so it must name that project.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'      IF NEW.project_id IS NOT NULL THEN' || E'\n' ||
'        RAISE EXCEPTION ''Help given to another project cannot also be booked to a project. These hours belong to neither project''''s budget.''' || E'\n' ||
'          USING ERRCODE = ''check_violation'';' || E'\n' ||
'      END IF;' || E'\n' ||
'    ELSIF NEW.related_project_id IS NOT NULL THEN' || E'\n' ||
'      RAISE EXCEPTION ''This time type does not record help given to another project, so it cannot name one.''' || E'\n' ||
'        USING ERRCODE = ''check_violation'';' || E'\n' ||
'    END IF;' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  RETURN NEW;' || E'\n' ||
'END;' || E'\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'enforce_timesheet_entry_rules';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'MIG 801: enforce_timesheet_entry_rules not found.';
  END IF;
  IF position('At least one activity is required for project time.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 801: rule (e) from mig 721 is missing. This is not the function the anchors were taken from.';
  END IF;

  IF position('uses_related_project' IN v_src) > 0 THEN
    RAISE NOTICE 'MIG 801: enforce_timesheet_entry_rules already carries rule (h). Nothing to do.';
  ELSE
    v_hits := (length(v_src) - length(replace(v_src, a_end, ''))) / length(a_end);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 801: tail anchor matched % times in enforce_timesheet_entry_rules, expected 1.', v_hits;
    END IF;

    v_new := replace(v_src, a_end, b_end);

    -- The new rule needs a declaration. Added next to the one rule (e) uses,
    -- which is the only DECLARE line this function is guaranteed to have.
    -- Whitespace in these declaration blocks is not consistent between the
    -- functions that carry them, so match on shape rather than on spacing.
    v_new := regexp_replace(v_new, '(\n[ \t]*v_needs_prj[ \t]+boolean;)',
                            E'\\1\n  v_uses_rel   boolean;');
    IF position('v_uses_rel' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 801: could not declare v_uses_rel -- no v_needs_prj declaration found.';
    END IF;

    EXECUTE v_new;
  END IF;
END $mig$;


-- ── 5. The write sites route the id ──────────────────────────────────────────

DO $mig$
DECLARE
  v_src text; v_new text; v_hits integer; v_fn text;

  a_route CONSTANT text :=
'  IF v_type.requires_project AND v_proj_id IS NULL THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''PROJECT_REQUIRED'',' || E'\n' ||
'      ''message'', ''This time type requires a project.'');' || E'\n' ||
'  END IF;' || E'\n';

  b_route CONSTANT text :=
'  IF v_type.requires_project AND v_proj_id IS NULL THEN' || E'\n' ||
'    RETURN jsonb_build_object(''ok'', false, ''error'', ''PROJECT_REQUIRED'',' || E'\n' ||
'      ''message'', ''This time type requires a project.'');' || E'\n' ||
'  END IF;' || E'\n' ||
'' || E'\n' ||
'  -- mig 801. On a type that records help, the id the employee chose names the' || E'\n' ||
'  -- project being HELPED. It goes to related_project_id and project_id stays' || E'\n' ||
'  -- NULL, which is what keeps these hours out of that project utilisation,' || E'\n' ||
'  -- burn and cost, and out of the caller own project dropdown for ever' || E'\n' ||
'  -- after. Everything else about the entry -- the activity rows, the daily' || E'\n' ||
'  -- cap, the merge rules -- is unchanged, because requires_project is still' || E'\n' ||
'  -- true and every one of those rules keys on it.' || E'\n' ||
'  v_rel_id := NULL;' || E'\n' ||
'  IF COALESCE(v_type.uses_related_project, false) THEN' || E'\n' ||
'    v_rel_id  := v_proj_id;' || E'\n' ||
'    v_proj_id := NULL;' || E'\n' ||
'  END IF;' || E'\n';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['save_timesheet_entry', 'bulk_create_timesheet_entries']
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'MIG 801: % not found.', v_fn;
    END IF;

    IF position('v_rel_id' IN v_src) > 0 THEN
      RAISE NOTICE 'MIG 801: % already routes the related project. Nothing to do.', v_fn;
      CONTINUE;
    END IF;

    -- (a) the type lookup must select the new flag, or v_type has no field.
    v_hits := (length(v_src) - length(replace(v_src, 'requires_project, allows_future INTO v_type', '')))
              / length('requires_project, allows_future INTO v_type');
    IF v_hits < 1 THEN
      RAISE EXCEPTION 'MIG 801: the time-type lookup in % is not shaped as expected.', v_fn;
    END IF;
    v_new := replace(v_src, 'requires_project, allows_future INTO v_type',
                            'requires_project, allows_future, uses_related_project INTO v_type');

    -- (b) the routing itself.
    v_hits := (length(v_new) - length(replace(v_new, a_route, ''))) / length(a_route);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 801: routing anchor matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, a_route, b_route);

    -- (c) the declaration.
    v_new := regexp_replace(v_new, '(\n[ \t]*v_proj_id[ \t]+uuid;)',
                            E'\\1\n  v_rel_id     uuid;');
    IF position('v_rel_id' IN v_new) = 0 THEN
      RAISE EXCEPTION 'MIG 801: could not declare v_rel_id in % -- no v_proj_id declaration found.', v_fn;
    END IF;

    -- (d) the INSERT carries the column.
    v_hits := (length(v_new) - length(replace(v_new, 'time_type_id, project_id,', '')))
              / length('time_type_id, project_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 801: INSERT column list matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, 'time_type_id, project_id,', 'time_type_id, project_id, related_project_id,');

    v_hits := (length(v_new) - length(replace(v_new, 'v_type_id, v_proj_id,', '')))
              / length('v_type_id, v_proj_id,');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'MIG 801: INSERT values list matched % times in %, expected 1.', v_hits, v_fn;
    END IF;
    v_new := replace(v_new, 'v_type_id, v_proj_id,', 'v_type_id, v_proj_id, v_rel_id,');

    -- (e) the UPDATE arm, where there is one.
    IF position('           project_id    = v_proj_id,' IN v_new) > 0 THEN
      v_new := replace(v_new, '           project_id    = v_proj_id,',
                              '           project_id    = v_proj_id,' || E'\n' ||
                              '           related_project_id = v_rel_id,');
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'MIG 801: % now routes the related project.', v_fn;
  END LOOP;
END $mig$;


-- ── 6. The unfiltered picker ─────────────────────────────────────────────────
--
-- A SEPARATE function, not a widening of my_timesheet_projects. That one narrows
-- to your own projects and is right to; this one deliberately does not narrow at
-- all, and the two answering different questions from one function would mean
-- every future change to either had to reason about both.
--
-- Bounded only by the project's own dates, per design decision D4. The accepted
-- consequence, stated so nobody discovers it: every employee can see the name of
-- every active project, prospects included. If that is ever to change, this
-- function is the single place it changes.

CREATE OR REPLACE FUNCTION public.bookable_projects_all(
  p_period_start date,
  p_period_end   date
)
RETURNS TABLE (
  id         uuid,
  name       text,
  start_date date,
  end_date   date
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT p.id, p.name, p.start_date, p.end_date
  FROM   projects p
  WHERE  p.active = true
    AND  (p.start_date IS NULL OR p.start_date <= p_period_end)
    AND  (p.end_date   IS NULL OR p.end_date   >= p_period_start)
    AND  p_period_start IS NOT NULL
    AND  p_period_end   IS NOT NULL
  ORDER  BY p.name;
$fn$;

REVOKE ALL ON FUNCTION public.bookable_projects_all(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bookable_projects_all(date, date) TO authenticated;

COMMENT ON FUNCTION public.bookable_projects_all(date, date) IS
  'Mig 801: every active project whose own window overlaps the period, with no '
  'membership narrowing whatever. For time types with uses_related_project, '
  'where the whole point is to name a project you are NOT on. Offers only; the '
  'rule that the hours land in related_project_id lives in the write path.';


-- ── 7. The type ──────────────────────────────────────────────────────────────
--
-- "Support to Another Project", not "Project Support": the word ANOTHER carries
-- the rule. Without it an assigned member doing production support on their own
-- project reaches for this, and the hours vanish from the project that is
-- paying for them -- the exact opposite of what the type exists to fix.
--
-- is_active = false. See the header: the frontend ships separately, and until
-- the unfiltered picker is live this type would offer the narrowed list.

INSERT INTO public.time_types
  (name, code, category, requires_project, uses_related_project, is_billable, is_active)
VALUES
  ('Support to Another Project', 'XPS', 'attendance', true, true, false, false)
ON CONFLICT (code) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
-- Verification
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_src text;
  n     integer;
BEGIN
  -- Columns.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='time_types'
                   AND column_name='uses_related_project' AND is_nullable='NO') THEN
    RAISE EXCEPTION 'MIG 801 FAILED: time_types.uses_related_project missing or nullable.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='timesheet_entries'
                   AND column_name='related_project_id') THEN
    RAISE EXCEPTION 'MIG 801 FAILED: timesheet_entries.related_project_id missing.';
  END IF;

  -- It must be a real reference, or the column is a free-text id in disguise.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints tc
    JOIN   information_schema.key_column_usage kcu
           ON kcu.constraint_name = tc.constraint_name
    WHERE  tc.table_name = 'timesheet_entries'
      AND  tc.constraint_type = 'FOREIGN KEY'
      AND  kcu.column_name = 'related_project_id') THEN
    RAISE EXCEPTION 'MIG 801 FAILED: related_project_id has no foreign key to projects.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname='public' AND indexname='idx_tse_related_project_date') THEN
    RAISE EXCEPTION 'MIG 801 FAILED: the reporting index is missing.';
  END IF;

  -- The flag can only be set where it means something.
  SELECT count(*) INTO n FROM public.time_types
  WHERE uses_related_project AND NOT requires_project;
  IF n <> 0 THEN
    RAISE EXCEPTION 'MIG 801 FAILED: % types use a related project without requiring a project.', n;
  END IF;

  -- The type.
  SELECT count(*) INTO n FROM public.time_types
  WHERE code='XPS' AND category='attendance' AND requires_project
    AND uses_related_project AND NOT is_billable;
  IF n <> 1 THEN
    RAISE EXCEPTION 'MIG 801 FAILED: the XPS type is missing or wrongly configured.';
  END IF;

  -- Whether XPS is active is an administrator's decision once the frontend is
  -- out, so it is NOT asserted. The migration guarantees only that it SHIPS
  -- inactive, which is a property of the INSERT above and not of the table on
  -- every future run. Asserting the state would make this migration fail the
  -- moment somebody did the thing it is asking them to do.
  SELECT count(*) INTO n FROM public.time_types WHERE code='XPS' AND is_active;
  IF n = 0 THEN
    RAISE NOTICE 'MIG 801: XPS is inactive, as shipped. Activate it on the Time Types screen once the frontend carrying the unfiltered picker is live.';
  ELSE
    RAISE NOTICE 'MIG 801: XPS is already active -- somebody has switched it on. Confirm the frontend picker is live.';
  END IF;

  -- The rule.
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname='public' AND p.proname='enforce_timesheet_entry_rules';
  IF position('uses_related_project' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 801 FAILED: rule (h) is not in the entry trigger.';
  END IF;
  IF position('At least one activity is required for project time.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'MIG 801 FAILED: the trigger lost rule (e) from 721.';
  END IF;

  -- The write path.
  FOR v_src IN
    SELECT pg_get_functiondef(p.oid)
    FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
    WHERE  n2.nspname='public'
      AND  p.proname IN ('save_timesheet_entry','bulk_create_timesheet_entries')
  LOOP
    IF position('v_rel_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 801 FAILED: a write path does not route the related project.';
    END IF;
    IF position('related_project_id' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 801 FAILED: a write path does not persist related_project_id.';
    END IF;
    IF position('uses_related_project INTO v_type' IN v_src) = 0 THEN
      RAISE EXCEPTION 'MIG 801 FAILED: a write path does not read the flag.';
    END IF;
  END LOOP;

  -- The picker offers, and narrows on nothing but dates.
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n2 ON n2.oid=p.pronamespace
                 WHERE n2.nspname='public' AND p.proname='bookable_projects_all') THEN
    RAISE EXCEPTION 'MIG 801 FAILED: bookable_projects_all not created.';
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM   pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE  n2.nspname='public' AND p.proname='bookable_projects_all';
  IF position('project_members' IN v_src) > 0 THEN
    RAISE EXCEPTION 'MIG 801 FAILED: bookable_projects_all narrows by membership. It must not.';
  END IF;

  RAISE NOTICE 'Migration 801 verified: related_project_id on entries, uses_related_project on time types, rule (h) in the trigger, both write paths routing, an unfiltered date-bounded picker, and XPS seeded INACTIVE pending the frontend.';
END $mig$;

COMMIT;
